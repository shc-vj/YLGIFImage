//
//  YLGIFImage.m
//  YLGIFImage
//
//  Created by Yong Li on 14-3-2.
//  Copyright (c) 2014年 Yong Li. All rights reserved.
//

#import "YLGIFImage.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <ImageIO/ImageIO.h>


//Define FLT_EPSILON because, reasons.
//Actually, I don't know why but it seems under certain circumstances it is not defined
#ifndef FLT_EPSILON
#define FLT_EPSILON __FLT_EPSILON__
#endif

inline static NSTimeInterval CGImageSourceGetGifFrameDelay(CGImageSourceRef imageSource, NSUInteger index)
{
    NSTimeInterval frameDuration = 0;
    CFDictionaryRef theImageProperties;
    if ((theImageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, index, NULL))) {
        CFDictionaryRef gifProperties;
        if (CFDictionaryGetValueIfPresent(theImageProperties, kCGImagePropertyGIFDictionary, (const void **)&gifProperties)) {
            const void *frameDurationValue;
            if (CFDictionaryGetValueIfPresent(gifProperties, kCGImagePropertyGIFUnclampedDelayTime, &frameDurationValue)) {
                frameDuration = [(__bridge NSNumber *)frameDurationValue doubleValue];
                if (frameDuration <= 0) {
                    if (CFDictionaryGetValueIfPresent(gifProperties, kCGImagePropertyGIFDelayTime, &frameDurationValue)) {
                        frameDuration = [(__bridge NSNumber *)frameDurationValue doubleValue];
                    }
                }
            }
        }
        CFRelease(theImageProperties);
    }
    
#ifndef OLExactGIFRepresentation
    //Implement as Browsers do.
    //See:  http://nullsleep.tumblr.com/post/16524517190/animated-gif-minimum-frame-delay-browser-compatibility
    //Also: http://blogs.msdn.com/b/ieinternals/archive/2010/06/08/animated-gifs-slow-down-to-under-20-frames-per-second.aspx
    
    if (frameDuration < 0.02 - FLT_EPSILON) {
        frameDuration = 0.1;
    }
#endif
    return frameDuration;
}

inline static BOOL CGImageSourceContainsAnimatedGif(CGImageSourceRef imageSource)
{
    return imageSource && UTTypeConformsTo(CGImageSourceGetType(imageSource), kUTTypeGIF) && CGImageSourceGetCount(imageSource) > 1;
}


CGFloat ResourceScaleFromPath(NSString *path)
{
	static NSRegularExpression *scaleRegEx = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSError *error;
		scaleRegEx = [NSRegularExpression regularExpressionWithPattern:@"@(\\d)x" options:NSRegularExpressionCaseInsensitive error:&error];
	});
	
	NSString *fileName = [[path lastPathComponent] stringByDeletingPathExtension];
	NSArray *results = [scaleRegEx matchesInString:fileName options:0 range:NSMakeRange(0, fileName.length)];
	
	NSTextCheckingResult *lastResult = [results lastObject];
	
	if( lastResult.numberOfRanges < 2 ) {
		// default scale
		return 1.0;
	}
	
	NSRange scaleRange = [lastResult rangeAtIndex:1];
	CGFloat scale = [[fileName substringWithRange:scaleRange] floatValue];
	
	return scale;
}

@interface YLGIFImage ()

@property (nonatomic, readwrite) NSMutableArray *images;
@property (nonatomic, readwrite) NSTimeInterval *frameDurations;
@property (nonatomic, readwrite) NSTimeInterval totalDuration;
@property (nonatomic, readwrite) NSUInteger loopCount;
@property (nonatomic, readwrite) CGImageSourceRef incrementalSource;

- (UIImage*)imageFromIndex:(NSUInteger)idx;

@end

static int _prefetchedNum = 10;

@implementation YLGIFImage
{
    dispatch_queue_t readFrameQueue;
    CGImageSourceRef _imageSourceRef;
    CGFloat _scale;
}

@synthesize images;

#pragma mark - Class Methods

+ (id)imageNamed:(NSString *)name
{
    NSString *path = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:name];
    
    return ([[NSFileManager defaultManager] fileExistsAtPath:path]) ? [self imageWithContentsOfFile:path] : nil;
}

+ (id)imageWithContentsOfFile:(NSString *)path
{
    return [self imageWithData:[NSData dataWithContentsOfFile:path]
                         scale:ResourceScaleFromPath(path)];
}

+ (id)imageWithData:(NSData *)data
{
    return [self imageWithData:data scale:1.0f];
}

+ (id)imageWithData:(NSData *)data scale:(CGFloat)scale
{
    if (!data) {
        return nil;
    }
    
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)(data), NULL);
    UIImage *image;
    
    if (CGImageSourceContainsAnimatedGif(imageSource)) {
        image = [[self alloc] initWithCGImageSource:imageSource scale:scale];
    } else {
        image = [super imageWithData:data scale:scale];
    }
    
    if (imageSource) {
        CFRelease(imageSource);
    }
    
    return image;
}

#pragma mark - Initialization methods

- (id)initWithContentsOfFile:(NSString *)path
{
    return [self initWithData:[NSData dataWithContentsOfFile:path]
                        scale:ResourceScaleFromPath(path)];
}

- (id)initWithData:(NSData *)data
{
    return [self initWithData:data scale:1.0f];
}

- (id)initWithData:(NSData *)data scale:(CGFloat)scale
{
    if (!data) {
        return nil;
    }
    
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)(data), NULL);
    
    if (CGImageSourceContainsAnimatedGif(imageSource)) {
        self = [self initWithCGImageSource:imageSource scale:scale];
    } else {
        if (scale == 1.0f) {
            self = [super initWithData:data];
        } else {
            self = [super initWithData:data scale:scale];
        }
    }
    
    if (imageSource) {
        CFRelease(imageSource);
    }
    
    return self;
}

- (id)initWithCGImageSource:(CGImageSourceRef)imageSource scale:(CGFloat)scale
{
    self = [super init];
    if (!imageSource || !self) {
        return nil;
    }
    
    CFRetain(imageSource);
    
    NSUInteger numberOfFrames = CGImageSourceGetCount(imageSource);
    
    NSDictionary *imageProperties = CFBridgingRelease(CGImageSourceCopyProperties(imageSource, NULL));
    NSDictionary *gifProperties = [imageProperties objectForKey:(NSString *)kCGImagePropertyGIFDictionary];
    
    self.frameDurations = (NSTimeInterval *)malloc(numberOfFrames  * sizeof(NSTimeInterval));
    self.loopCount = [gifProperties[(NSString *)kCGImagePropertyGIFLoopCount] unsignedIntegerValue];
    self.images = [NSMutableArray arrayWithCapacity:numberOfFrames];
    
    NSNull *aNull = [NSNull null];
    for (NSUInteger i = 0; i < numberOfFrames; ++i) {
        [self.images addObject:aNull];
        NSTimeInterval frameDuration = CGImageSourceGetGifFrameDelay(imageSource, i);
        self.frameDurations[i] = frameDuration;
        self.totalDuration += frameDuration;
    }
    //CFTimeInterval start = CFAbsoluteTimeGetCurrent();
	
	_imageSourceRef = imageSource;
	CFRetain(_imageSourceRef);
	CFRelease(imageSource);

	_scale = scale;

	readFrameQueue = dispatch_queue_create("com.ronnie.gifreadframe", DISPATCH_QUEUE_CONCURRENT);
	
	// Prefetch frames
	NSUInteger num = MIN(_prefetchedNum, numberOfFrames);
    for (int i=0; i<num; i++) {
		dispatch_async(readFrameQueue, ^{
			[self imageFromIndex:i];
		});
	}
	
	
    return self;
}

- (UIImage*)imageFromIndex:(NSUInteger)idx
{
	CGImageRef image = CGImageSourceCreateImageAtIndex(self->_imageSourceRef, idx, NULL);
	UIImage *uiImage = [UIImage imageWithCGImage:image scale:self.scale orientation:self.imageOrientation];
	CFRelease(image);
	
	[self.images replaceObjectAtIndex:idx withObject:uiImage];
	
	return uiImage;
}

- (UIImage*)getFrameWithIndex:(NSUInteger)idx
{
	__block UIImage *frame = nil;
	
	dispatch_barrier_sync(readFrameQueue, ^{
		id entry = self.images[idx];

		if( [entry isKindOfClass:NSNull.class] ) {
			frame = [self imageFromIndex:idx];
		} else {
			frame = entry;
		}
	
		if(self.images.count > _prefetchedNum) {
			// discard previous image
			if(idx > 0) {
				[self.images replaceObjectAtIndex:idx-1 withObject:[NSNull null]];
			} else {
				[self.images replaceObjectAtIndex:self.images.count-1 withObject:[NSNull null]];
			}
			// check for precached images
			NSUInteger nextReadIdx = (idx + _prefetchedNum);
			for(NSUInteger i=idx+1; i<=nextReadIdx; i++) {
				NSUInteger _idx = i%self.images.count;
				if([self.images[_idx] isKindOfClass:[NSNull class]]) {
					dispatch_async(self->readFrameQueue, ^{
						[self imageFromIndex:_idx];
					});
				}
			}
		}
	});
	
	return frame;
}

#pragma mark - Compatibility methods

- (CGSize)size
{
    if (self.images.count) {
		UIImage *uiImage = [self getFrameWithIndex:0];
		return [uiImage size];
	} else {
    	return [super size];
	}
}

- (CIImage*)CIImage
{
	if (self.images.count) {
		UIImage *uiImage = [self getFrameWithIndex:0];
		CGImageRef image =  uiImage.CGImage;
		return 	[CIImage imageWithCGImage:image];
	} else {
		return [super CIImage];
	}
}

- (CGImageRef)CGImage
{
    if (self.images.count) {
		UIImage *uiImage = [self getFrameWithIndex:0];
		return uiImage.CGImage;
    } else {
        return [super CGImage];
    }
}

- (UIImageOrientation)imageOrientation
{
    if (self.images.count) {
		return UIImageOrientationUp;
    } else {
        return [super imageOrientation];
    }
}

- (CGFloat)scale
{
    if (self.images.count) {
		return _scale;
    } else {
        return [super scale];
    }
}

- (NSTimeInterval)duration
{
    return self.images ? self.totalDuration : [super duration];
}

- (void)dealloc {
    if(_imageSourceRef) {
        CFRelease(_imageSourceRef);
    }
    free(_frameDurations);
    if (_incrementalSource) {
        CFRelease(_incrementalSource);
    }
}

@end
