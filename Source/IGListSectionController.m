/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "IGListSectionControllerInternal.h"

#import <IGListKit/IGListMacros.h>
#import <IGListKit/IGListAssert.h>

static NSString * const kIGListSectionControllerThreadKey = @"kIGListSectionControllerThreadKey";

@interface IGListSectionControllerThreadContext : NSObject
@property (nonatomic, weak) UIViewController *viewController;
@property (nonatomic, weak) id<IGListCollectionContext> collectionContext;
@end
@implementation IGListSectionControllerThreadContext
@end


/**
 这个 context stack 相当于全局的 manager
 */
static NSMutableArray<IGListSectionControllerThreadContext *> *threadContextStack(void) {
    IGAssertMainThread();
    NSMutableDictionary *threadDictionary = [[NSThread currentThread] threadDictionary];
    NSMutableArray *stack = threadDictionary[kIGListSectionControllerThreadKey];
    if (stack == nil) {
        stack = [NSMutableArray new];
        threadDictionary[kIGListSectionControllerThreadKey] = stack;
    }
    return stack;
}

/**
 在 thread stack 中增加一项，这一项就是 view controller 以及对应的 context
 */
void IGListSectionControllerPushThread(UIViewController *viewController, id<IGListCollectionContext> collectionContext) {
    IGListSectionControllerThreadContext *context = [IGListSectionControllerThreadContext new];
    context.viewController = viewController;
    context.collectionContext = collectionContext;

    [threadContextStack() addObject:context];
}

/**
 在 thread stack 删除一项
 */
void IGListSectionControllerPopThread(void) {
    NSMutableArray *stack = threadContextStack();
    IGAssert(stack.count > 0, @"IGListSectionController thread stack is empty");
    [stack removeLastObject];
}

@implementation IGListSectionController

- (instancetype)init {
    if (self = [super init]) {
        // 每次初始化一个新的 Section ，都要从 thread stack 中获取栈顶的 cxt
        // 每次在 init section controller 之前，都会将 view controller 和对应的 adapter Push
        // 这样，section 就能耦合的获取到对应的 cxt （因为 adapter dupdate 一定会创建 section controller）
        IGListSectionControllerThreadContext *context = [threadContextStack() lastObject];
        _viewController = context.viewController;
        _collectionContext = context.collectionContext;

        if (_collectionContext == nil) {
            IGLKLog(@"Warning: Creating %@ outside of -[IGListAdapterDataSource listAdapter:sectionControllerForObject:]. Collection context and view controller will be set later.",
                    NSStringFromClass([self class]));
        }

        _minimumInteritemSpacing = 0.0;
        _minimumLineSpacing = 0.0;
        _inset = UIEdgeInsetsZero;
        _section = NSNotFound;
    }
    return self;
}

- (NSInteger)numberOfItems {
    return 1;
}

- (CGSize)sizeForItemAtIndex:(NSInteger)index {
    return CGSizeZero;
}

// 很多方法都是需要 subclass 去实现的
- (__kindof UICollectionViewCell *)cellForItemAtIndex:(NSInteger)index {
    IGFailAssert(@"Section controller %@ must override %s:", self, __PRETTY_FUNCTION__);
    return nil;
}

- (void)didUpdateToObject:(id)object {}

- (void)didSelectItemAtIndex:(NSInteger)index {}

- (void)didDeselectItemAtIndex:(NSInteger)index {}

- (void)didHighlightItemAtIndex:(NSInteger)index {}

- (void)didUnhighlightItemAtIndex:(NSInteger)index {}
    
- (BOOL)canMoveItemAtIndex:(NSInteger)index {
    return NO;
}

- (BOOL)canMoveItemAtIndex:(NSInteger)sourceItemIndex toIndex:(NSInteger)destinationItemIndex {
    return [self canMoveItemAtIndex:sourceItemIndex];
}
    
- (void)moveObjectFromIndex:(NSInteger)sourceIndex toIndex:(NSInteger)destinationIndex {
    IGFailAssert(@"Section controller %@ must override %s if interactive reordering is enabled.", self, __PRETTY_FUNCTION__);
}

@end
