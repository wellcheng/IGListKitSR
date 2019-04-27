/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "IGListAdapter+UICollectionView.h"

#import <IGListKit/IGListAdapterInternal.h>
#import <IGListKit/IGListAssert.h>
#import <IGListKit/IGListSectionController.h>
#import <IGListKit/IGListSectionControllerInternal.h>
#import <IGListKit/UICollectionViewLayout+InteractiveReordering.h>

@implementation IGListAdapter (UICollectionView)

#pragma mark - UICollectionViewDataSource

// 这个就是 collection 真正开始与 collection view 交互的地方
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    // 每一个原始的 object 就是一个 section
    return self.sectionMap.objects.count;
}

// SectionController 也是可以包含其他 controller 的
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    IGListSectionController * sectionController = [self sectionControllerForSection:section];
    IGAssert(sectionController != nil, @"Nil section controller for section %li for item %@. Check your -diffIdentifier and -isEqual: implementations.",
             (long)section, [self.sectionMap objectForSection:section]);
    const NSInteger numberOfItems = [sectionController numberOfItems];
    IGAssert(numberOfItems >= 0, @"Cannot return negative number of items %li for section controller %@.", (long)numberOfItems, sectionController);
    return numberOfItems;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    // 如果要自己监听 IG 的处理时间，可以实现 IGListAdapterPerformanceDelegate 
    id<IGListAdapterPerformanceDelegate> performanceDelegate = self.performanceDelegate;
    [performanceDelegate listAdapterWillCallDequeueCell:self];

    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];

    // Cell 是由 section controller 创建的
    // flag that a cell is being dequeued in case it tries to access a cell in the process
    _isDequeuingCell = YES;
    UICollectionViewCell *cell = [sectionController cellForItemAtIndex:indexPath.item];
    _isDequeuingCell = NO;

    IGAssert(cell != nil, @"Returned a nil cell at indexPath <%@> from section controller: <%@>", indexPath, sectionController);

    // associate the section controller with the cell so that we know which section controller is using it
    // 根据 view 也能快速得到 section controller
    [self mapView:cell toSectionController:sectionController];

    [performanceDelegate listAdapter:self didCallDequeueCell:cell onSectionController:sectionController atIndex:indexPath.item];
    return cell;
}

// header and footer
- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    // 先通过 controller 得到创建 header 的服务，然后再创建 header
    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    id <IGListSupplementaryViewSource> supplementarySource = [sectionController supplementaryViewSource];
    UICollectionReusableView *view = [supplementarySource viewForSupplementaryElementOfKind:kind atIndex:indexPath.item];
    IGAssert(view != nil, @"Returned a nil supplementary view at indexPath <%@> from section controller: <%@>, supplementary source: <%@>", indexPath, sectionController, supplementarySource);

    // associate the section controller with the cell so that we know which section controller is using it
    [self mapView:view toSectionController:sectionController];

    return view;
}
    
- (BOOL)collectionView:(UICollectionView *)collectionView canMoveItemAtIndexPath:(NSIndexPath *)indexPath {
    const NSInteger sectionIndex = indexPath.section;
    const NSInteger itemIndex = indexPath.item;
    
    IGListSectionController *sectionController = [self sectionControllerForSection:sectionIndex];
    return [sectionController canMoveItemAtIndex:itemIndex];
}
    
- (void)collectionView:(UICollectionView *)collectionView
   moveItemAtIndexPath:(NSIndexPath *)sourceIndexPath
           toIndexPath:(NSIndexPath *)destinationIndexPath {

    if (@available(iOS 9.0, *)) {
        const NSInteger sourceSectionIndex = sourceIndexPath.section;
        const NSInteger destinationSectionIndex = destinationIndexPath.section;
        const NSInteger sourceItemIndex = sourceIndexPath.item;
        const NSInteger destinationItemIndex = destinationIndexPath.item;

        IGListSectionController *sourceSectionController = [self sectionControllerForSection:sourceSectionIndex];
        IGListSectionController *destinationSectionController = [self sectionControllerForSection:destinationSectionIndex];

        // this is a move within a section
        if (sourceSectionController == destinationSectionController) {
            // section controller 内部进行移动
            if ([sourceSectionController canMoveItemAtIndex:sourceItemIndex toIndex:destinationItemIndex]) {
                [self moveInSectionControllerInteractive:sourceSectionController
                                               fromIndex:sourceItemIndex
                                                 toIndex:destinationItemIndex];
            } else {
                // otherwise this is a move of an _item_ from one section to another section
                // we need to revert the change as it's too late to cancel
                // 这是一个非法的移动，需要 revert
                [self revertInvalidInteractiveMoveFromIndexPath:sourceIndexPath toIndexPath:destinationIndexPath];
            }
            return;
        }

        // this is a reordering of sections themselves
        // 如果 sec controller 都只有一个 cell，那么直接移动 section controller
        if ([sourceSectionController numberOfItems] == 1 && [destinationSectionController numberOfItems] == 1) {

            // perform view changes in the collection view
            [self moveSectionControllerInteractive:sourceSectionController
                                         fromIndex:sourceSectionIndex
                                           toIndex:destinationSectionIndex];
            return;
        }

        // otherwise this is a move of an _item_ from one section to another section
        // this is not currently supported, so we need to revert the change as it's too late to cancel
        [self revertInvalidInteractiveMoveFromIndexPath:sourceIndexPath toIndexPath:destinationIndexPath];
    }
}

#pragma mark - UICollectionViewDelegate

// collectionViewDelegate 有可能是 proxy
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didSelectItemAtIndexPath:indexPath];
    }

    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    [sectionController didSelectItemAtIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView didDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didDeselectItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didDeselectItemAtIndexPath:indexPath];
    }

    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    [sectionController didDeselectItemAtIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    id<IGListAdapterPerformanceDelegate> performanceDelegate = self.performanceDelegate;
    [performanceDelegate listAdapterWillCallDisplayCell:self];

    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:willDisplayCell:forItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView willDisplayCell:cell forItemAtIndexPath:indexPath];
    }

    IGListSectionController *sectionController = [self sectionControllerForView:cell];
    // if the section controller relationship was destroyed, reconnect it
    // this happens with iOS 10 UICollectionView display range changes
    if (sectionController == nil) {
        sectionController = [self sectionControllerForSection:indexPath.section];
        [self mapView:cell toSectionController:sectionController];
    }

    // 触发 displayer 的回调 ，表示 cell 即将展现（其实最终也会展现）
    id object = [self.sectionMap objectForSection:indexPath.section];
    [self.displayHandler willDisplayCell:cell forListAdapter:self sectionController:sectionController object:object indexPath:indexPath];
    
    // 触发 cell 时否进入工作区域，比如进行提前加载资源和刷新
    _isSendingWorkingRangeDisplayUpdates = YES;
    [self.workingRangeHandler willDisplayItemAtIndexPath:indexPath forListAdapter:self];
    _isSendingWorkingRangeDisplayUpdates = NO;

    // 性能统计
    [performanceDelegate listAdapter:self didCallDisplayCell:cell onSectionController:sectionController atIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    id<IGListAdapterPerformanceDelegate> performanceDelegate = self.performanceDelegate;
    [performanceDelegate listAdapterWillCallEndDisplayCell:self];

    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didEndDisplayingCell:forItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didEndDisplayingCell:cell forItemAtIndexPath:indexPath];
    }

    IGListSectionController *sectionController = [self sectionControllerForView:cell];
    [self.displayHandler didEndDisplayingCell:cell forListAdapter:self sectionController:sectionController indexPath:indexPath];
    [self.workingRangeHandler didEndDisplayingItemAtIndexPath:indexPath forListAdapter:self];

    // break the association between the cell and the section controller
    [self removeMapForView:cell];

    [performanceDelegate listAdapter:self didCallEndDisplayCell:cell onSectionController:sectionController atIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView willDisplaySupplementaryView:(UICollectionReusableView *)view forElementKind:(NSString *)elementKind atIndexPath:(NSIndexPath *)indexPath {
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView willDisplaySupplementaryView:view forElementKind:elementKind atIndexPath:indexPath];
    }

    IGListSectionController *sectionController = [self sectionControllerForView:view];
    // if the section controller relationship was destroyed, reconnect it
    // this happens with iOS 10 UICollectionView display range changes
    if (sectionController == nil) {
        sectionController = [self.sectionMap sectionControllerForSection:indexPath.section];
        [self mapView:view toSectionController:sectionController];
    }

    id object = [self.sectionMap objectForSection:indexPath.section];
    [self.displayHandler willDisplaySupplementaryView:view forListAdapter:self sectionController:sectionController object:object indexPath:indexPath];
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingSupplementaryView:(UICollectionReusableView *)view forElementOfKind:(NSString *)elementKind atIndexPath:(NSIndexPath *)indexPath {
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didEndDisplayingSupplementaryView:forElementOfKind:atIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didEndDisplayingSupplementaryView:view forElementOfKind:elementKind atIndexPath:indexPath];
    }

    IGListSectionController *sectionController = [self sectionControllerForView:view];
    [self.displayHandler didEndDisplayingSupplementaryView:view forListAdapter:self sectionController:sectionController indexPath:indexPath];

    [self removeMapForView:view];
}

- (void)collectionView:(UICollectionView *)collectionView didHighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didHighlightItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didHighlightItemAtIndexPath:indexPath];
    }

    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    [sectionController didHighlightItemAtIndex:indexPath.item];
}

- (void)collectionView:(UICollectionView *)collectionView didUnhighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    // forward this method to the delegate b/c this implementation will steal the message from the proxy
    id<UICollectionViewDelegate> collectionViewDelegate = self.collectionViewDelegate;
    if ([collectionViewDelegate respondsToSelector:@selector(collectionView:didUnhighlightItemAtIndexPath:)]) {
        [collectionViewDelegate collectionView:collectionView didUnhighlightItemAtIndexPath:indexPath];
    }

    IGListSectionController * sectionController = [self sectionControllerForSection:indexPath.section];
    [sectionController didUnhighlightItemAtIndex:indexPath.item];
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    IGAssert(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    
    // size 委托给 adapter
    CGSize size = [self sizeForItemAtIndexPath:indexPath];
    IGAssert(!isnan(size.height), @"IGListAdapter returned NaN height = %f for item at indexPath <%@>", size.height, indexPath);
    IGAssert(!isnan(size.width), @"IGListAdapter returned NaN width = %f for item at indexPath <%@>", size.width, indexPath);

    return size;
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout insetForSectionAtIndex:(NSInteger)section {
    IGAssert(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    
    // layout 委托给 section
    return [[self sectionControllerForSection:section] inset];
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    IGAssert(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    
    // layout 委托给 section
    return [[self sectionControllerForSection:section] minimumLineSpacing];
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    IGAssert(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    
    // layout 委托给 section
    return [[self sectionControllerForSection:section] minimumInteritemSpacing];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForHeaderInSection:(NSInteger)section {
    IGAssert(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:0 inSection:section];
    return [self sizeForSupplementaryViewOfKind:UICollectionElementKindSectionHeader atIndexPath:indexPath];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout referenceSizeForFooterInSection:(NSInteger)section {
    IGAssert(![self.collectionViewDelegate respondsToSelector:_cmd], @"IGListAdapter is consuming method also implemented by the collectionViewDelegate: %@", NSStringFromSelector(_cmd));
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:0 inSection:section];
    return [self sizeForSupplementaryViewOfKind:UICollectionElementKindSectionFooter atIndexPath:indexPath];
}

#pragma mark - IGListCollectionViewDelegateLayout

- (UICollectionViewLayoutAttributes *)collectionView:(UICollectionView *)collectionView
                                              layout:(UICollectionViewLayout*)collectionViewLayout
                   customizedInitialLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes
                                         atIndexPath:(NSIndexPath *)indexPath {
    
    // transitionDelegate 提供 cell 具体的 layout attr
    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    if (sectionController.transitionDelegate) {
        return [sectionController.transitionDelegate listAdapter:self
                               customizedInitialLayoutAttributes:attributes
                                               sectionController:sectionController
                                                         atIndex:indexPath.item];
    }
    return attributes;
}

- (UICollectionViewLayoutAttributes *)collectionView:(UICollectionView *)collectionView
                                              layout:(UICollectionViewLayout*)collectionViewLayout
                     customizedFinalLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes
                                         atIndexPath:(NSIndexPath *)indexPath {
    
    // transitionDelegate 提供 cell 具体的 layout attr
    IGListSectionController *sectionController = [self sectionControllerForSection:indexPath.section];
    if (sectionController.transitionDelegate) {
        return [sectionController.transitionDelegate listAdapter:self
                                 customizedFinalLayoutAttributes:attributes
                                               sectionController:sectionController
                                                         atIndex:indexPath.item];
    }
    return attributes;
}

@end
