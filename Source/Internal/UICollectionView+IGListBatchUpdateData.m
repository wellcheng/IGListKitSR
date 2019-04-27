/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "UICollectionView+IGListBatchUpdateData.h"

#import <IGListKit/IGListBatchUpdateData.h>

@implementation UICollectionView (IGListBatchUpdateData)

- (void)ig_applyBatchUpdateData:(IGListBatchUpdateData *)updateData {
    // 这里的方式是真正更新 collection 的地方
    // 因为都使用了 section 作为基础单元，因此都是 section 的 API
    
    // 1、进行 item 层面的数据刷新
    [self deleteItemsAtIndexPaths:updateData.deleteIndexPaths];
    [self insertItemsAtIndexPaths:updateData.insertIndexPaths];
    [self reloadItemsAtIndexPaths:updateData.updateIndexPaths];

    // 2、移动操作要一步一步来
    for (IGListMoveIndexPath *move in updateData.moveIndexPaths) {
        [self moveItemAtIndexPath:move.from toIndexPath:move.to];
    }

    // 3、先进行 section 的移动
    for (IGListMoveIndex *move in updateData.moveSections) {
        [self moveSection:move.from toSection:move.to];
    }

    // 4、Section 的增加和删除
    [self deleteSections:updateData.deleteSections];
    [self insertSections:updateData.insertSections];
}

@end
