//
//  VELNSView.m
//  Velvet
//
//  Created by Justin Spahr-Summers on 20.11.11.
//  Copyright (c) 2011 Bitswift. All rights reserved.
//

#import <Velvet/VELNSView.h>
#import <Velvet/CATransaction+BlockAdditions.h>
#import <Velvet/CGBitmapContext+PixelFormatAdditions.h>
#import <Velvet/NSVelvetView.h>
#import <Velvet/NSVelvetViewPrivate.h>
#import <Velvet/NSView+VELBridgedViewAdditions.h>
#import <Velvet/VELNSViewPrivate.h>
#import <Proton/Proton.h>
#import <QuartzCore/QuartzCore.h>

@interface VELNSView ()
@property (nonatomic, assign) BOOL rendersContainedView;

- (void)synchronizeNSViewGeometry;
@end

@implementation VELNSView

#pragma mark Properties

@synthesize guestView = m_guestView;
@synthesize rendersContainedView = m_rendersContainedView;

- (void)setGuestView:(NSView *)view {
    NSAssert1([NSThread isMainThread], @"%s should only be called from the main thread", __func__);

    // remove any existing guest view
    [m_guestView removeFromSuperview];
    m_guestView.hostView = nil;

    m_guestView = view;

    NSVelvetView *velvetView = self.ancestorNSVelvetView;

    // and set up our new view
    if (m_guestView) {
        // set up layer-backing on the view
        [m_guestView setWantsLayer:YES];
        [m_guestView setNeedsDisplay:YES];

        [velvetView.appKitHostView addSubview:m_guestView];
        m_guestView.hostView = self;

        [velvetView recalculateNSViewOrdering];

        m_guestView.nextResponder = self;
    }

    [velvetView recalculateNSViewClipping];
}

- (CGRect)NSViewFrame; {
    // we use 'self' and 'bounds' here instead of the superview and frame
    // because the superview may be a VELScrollView, and accessing it directly
    // will skip over the CAScrollLayer that's in the hierarchy
    return [self convertRect:self.bounds toView:self.ancestorNSVelvetView.guestView];
}

- (void)setCenter:(CGPoint)center {
    [super setCenter:center];
    [self synchronizeNSViewGeometry];
}

- (void)setSubviews:(NSArray *)subviews {
    NSAssert2(![subviews count], @"%@ must be a leaf in the Velvet hierarchy, cannot add subviews: %@", self, subviews);

    // if assertions are disabled, proceed anyways (better to glitch out than
    // crash)
    [super setSubviews:subviews];
}

#pragma mark Lifecycle

- (id)init {
    self = [super init];
    if (!self)
        return nil;

    self.layer.masksToBounds = NO;
    return self;
}

- (id)initWithNSView:(NSView *)view; {
    NSAssert1([NSThread isMainThread], @"%s should only be called from the main thread", __func__);

    self = [self init];
    if (!self)
        return nil;

    self.guestView = view;
    self.frame = view.frame;
    return self;
}

- (void)dealloc {
    self.guestView.hostView = nil;
}

#pragma mark Geometry

- (void)synchronizeNSViewGeometry; {
    NSAssert1([NSThread isMainThread], @"%s should only be called from the main thread", __func__);

    if (!self.window) {
        // can't do this without being in a window
        return;
    }

    NSAssert(self.ancestorNSVelvetView, @"%@ should be in an NSVelvetView if it has a window", self);

    CGRect frame = self.NSViewFrame;
    self.guestView.frame = frame;

    [self.ancestorNSVelvetView recalculateNSViewClipping];
}

#pragma mark View hierarchy

- (void)ancestorDidLayout; {
    [self synchronizeNSViewGeometry];
    [super ancestorDidLayout];
}

- (void)willMoveToNSVelvetView:(NSVelvetView *)view; {
    [super willMoveToNSVelvetView:view];

    [self.guestView willMoveToNSVelvetView:view];
    [self.guestView removeFromSuperview];
}

- (void)didMoveFromNSVelvetView:(NSVelvetView *)view; {
    [super didMoveFromNSVelvetView:view];

    @onExit {
        [self.guestView didMoveFromNSVelvetView:view];
    };

    NSVelvetView *newView = self.ancestorNSVelvetView;
    if (!newView) {
        return;
    }

    // verify that VELNSViews are on top of other subviews
    #if DEBUG
    NSArray *siblings = self.superview.subviews;
    __block BOOL foundVelvetView = NO;

    [siblings enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(VELView *view, NSUInteger index, BOOL *stop){
        if ([view isKindOfClass:[VELNSView class]]) {
            NSAssert2(!foundVelvetView, @"%@ must be on top of its sibling VELViews: %@", view, siblings);
        } else {
            foundVelvetView = YES;
        }
    }];
    #endif

    // this must only be added after we've completely moved to the host view,
    // because it'll do some ancestor checks for NSView ordering
    [newView.appKitHostView addSubview:self.guestView];

    [newView recalculateNSViewOrdering];
    [self synchronizeNSViewGeometry];

    self.guestView.nextResponder = self;
}

- (id<VELBridgedView>)descendantViewAtPoint:(CGPoint)point {
    if (![self pointInside:point])
        return nil;

    CGPoint NSViewPoint = [self.guestView convertFromWindowPoint:[self convertToWindowPoint:point]];

    // never return 'self', since we don't want to catch clicks that didn't
    // directly hit the NSView
    return [self.guestView descendantViewAtPoint:NSViewPoint];
}

#pragma mark Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    [self synchronizeNSViewGeometry];
}

- (CGSize)sizeThatFits:(CGSize)constraint {
    NSAssert1([NSThread isMainThread], @"%s should only be called from the main thread", __func__);

    id view = self.guestView;
    NSSize cellSize = NSMakeSize(10000, 10000);

    NSCell *cell = nil;

    if ([view respondsToSelector:@selector(cell)]) {
        cell = [view cell];
    }

    if ([cell respondsToSelector:@selector(cellSize)]) {
        cellSize = [cell cellSize];
    }

    // if we don't have a cell, or it didn't give us a true size
    if (CGSizeEqualToSize(cellSize, CGSizeMake(10000, 10000))) {
        return [super sizeThatFits:constraint];
    }

    return cellSize;
}

#pragma mark NSObject overrides

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %p> frame = %@, NSView = %@ %@", [self class], self, NSStringFromRect(self.frame), self.guestView, NSStringFromRect(self.guestView.frame)];
}

#pragma mark CALayer delegate

- (void)renderContainedViewInLayer:(CALayer *)layer {
    CGContextRef context = CGBitmapContextCreateGeneric(self.bounds.size, YES);

    [self.guestView.layer renderInContext:context];

    CGImageRef image = CGBitmapContextCreateImage(context);
    layer.contents = (__bridge_transfer id)image;

    CGContextRelease(context);
}

- (void)setRendersContainedView:(BOOL)rendersContainedView {
    NSAssert1([NSThread isMainThread], @"%s should only be called from the main thread", __func__);

    if (m_rendersContainedView != rendersContainedView) {
        m_rendersContainedView = rendersContainedView;
        if (rendersContainedView) {
            [CATransaction performWithDisabledActions:^{
                [self renderContainedViewInLayer:self.layer];
            }];
        } else {
            [CATransaction performWithDisabledActions:^{
                self.layer.contents = nil;
            }];
        }
    }
}

@end
