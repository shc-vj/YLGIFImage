//
//  YLImageView.m
//  YLGIFImage
//
//  Created by Yong Li on 14-3-2.
//  Copyright (c) 2014年 Yong Li. All rights reserved.
//

#import "YLImageView.h"
#import "YLGIFImage.h"
#import <QuartzCore/QuartzCore.h>

@interface YLImageView ()

@property (nonatomic, strong) YLGIFImage *animatedImage;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic) NSTimeInterval accumulator;
@property (nonatomic) NSUInteger currentFrameIndex;
@property (nonatomic, strong) UIImage *currentFrame;
@property (nonatomic) NSUInteger loopCountdown;

@end

@implementation YLImageView

const NSTimeInterval kMaxTimeStep = 1; // note: To avoid spiral-o-death

@synthesize runLoopMode = _runLoopMode;
@synthesize displayLink = _displayLink;
@synthesize currentFrameIndex = _currentFrameIndex;

- (id)init
{
    self = [super init];
    if (self) {
        self.currentFrameIndex = 0;
    }
    return self;
}

- (CADisplayLink *)displayLink
{
	if( self.window && self.animatedImage ) {
        if (!_displayLink) {
            _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(changeKeyframe:)];
            [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:self.runLoopMode];
        }
    } else {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    return _displayLink;
}

- (NSString *)runLoopMode
{
	return _runLoopMode ?: NSRunLoopCommonModes;
}

- (void)setRunLoopMode:(NSString *)runLoopMode
{
    if (runLoopMode != _runLoopMode) {
        [self stopAnimating];
        
        NSRunLoop *runloop = [NSRunLoop mainRunLoop];
        [self.displayLink removeFromRunLoop:runloop forMode:_runLoopMode];
        [self.displayLink addToRunLoop:runloop forMode:runLoopMode];
        
        _runLoopMode = runLoopMode;
        
        [self startAnimating];
    }
}

- (void)setImage:(UIImage *)image
{
    if (image == self.image) {
        return;
    }
    
    [self stopAnimating];
    
    self.currentFrameIndex = 0;
    self.loopCountdown = 0;
    self.accumulator = 0;
	
	
    if ([image isKindOfClass:[YLGIFImage class]] ) {
		YLGIFImage *gifImage = (YLGIFImage*)image;

		if( gifImage.images.count <= 1 ) {
			self.animatedImage = nil;
			[super setImage:image];
		} else {
			UIImage *firstImage = [gifImage getFrameWithIndex:0];
			[super setImage:firstImage];

			self.animatedImage = (YLGIFImage *)image;
		}
		
        self.currentFrame = nil;
        self.loopCountdown = self.animatedImage.loopCount ?: NSUIntegerMax;
    } else {
        self.animatedImage = nil;
		[super setImage:image];
    }
    [self.layer setNeedsDisplay];
}

- (void)setAnimatedImage:(YLGIFImage *)animatedImage
{
    _animatedImage = animatedImage;
    if (animatedImage == nil) {
        self.layer.contents = nil;
    }
}

- (BOOL)isAnimating
{
    return [super isAnimating] || (self.displayLink && !self.displayLink.isPaused);
}

- (void)stopAnimating
{
    if (!self.animatedImage) {
        [super stopAnimating];
        return;
    }
    
	self.currentFrameIndex = 0;
	self.loopCountdown = 0;
    
	self.displayLink.paused = YES;
}

- (void)pauseAnimating
{
	if (!self.animatedImage) {
		return;
	}
	
	self.displayLink.paused = YES;
}

- (void)startAnimating
{
    if (!self.animatedImage) {
        [super startAnimating];
        return;
    }
	
	self.displayLink.paused = NO;
	
    self.loopCountdown = self.animatedImage.loopCount ?: NSUIntegerMax;
}

- (void)changeKeyframe:(CADisplayLink *)displayLink
{
	if (self.currentFrameIndex >= [self.animatedImage.images count]) {
        return;
    }
	
	
	NSUInteger prevFrame = self.currentFrameIndex;
	
	self.accumulator += fmin(displayLink.duration, kMaxTimeStep);
    
    while (self.accumulator >= self.animatedImage.frameDurations[_currentFrameIndex]) {
        self.accumulator -= self.animatedImage.frameDurations[_currentFrameIndex];
        if (++_currentFrameIndex >= [self.animatedImage.images count]) {
            if (--self.loopCountdown == 0) {
                [self stopAnimating];
                return;
            }
            self.currentFrameIndex = 0;
        }
	}
	
	if( self.currentFrameIndex != prevFrame ) {
		self.currentFrameIndex = MIN(self.currentFrameIndex, [self.animatedImage.images count] - 1);
		self.currentFrame = [self.animatedImage getFrameWithIndex:self.currentFrameIndex];
		[self.layer setNeedsDisplay];
	}
}

- (void)displayLayer:(CALayer *)layer
{
	if (!self.animatedImage || [self.animatedImage.images count] == 0) {
		if( @available(iOS 14, *) ) {
			if( [super respondsToSelector:@selector(displayLayer:)] ) {
				[super displayLayer:layer];
			}
		}
		return;
	}

	
    //NSLog(@"display index: %luu", (unsigned long)self.currentFrameIndex);
	if(self.currentFrame) {
        layer.contents = (__bridge id)self.currentFrame.CGImage;
	}
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    if (self.window) {
        [self startAnimating];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.window) {
                [self stopAnimating];
            }
        });
    }
}

- (void)didMoveToSuperview
{
    [super didMoveToSuperview];
    if (self.superview) {
        //Has a superview, make sure it has a displayLink
        [self displayLink];
    } else {
        //Doesn't have superview, let's check later if we need to remove the displayLink
        dispatch_async(dispatch_get_main_queue(), ^{
            [self displayLink];
        });
    }
}

- (void)setHighlighted:(BOOL)highlighted
{
    if (!self.animatedImage) {
        [super setHighlighted:highlighted];
    }
}

- (UIImage *)image
{
    return self.animatedImage ?: [super image];
}

- (CGSize)sizeThatFits:(CGSize)size
{
    return self.image.size;
}


@end

