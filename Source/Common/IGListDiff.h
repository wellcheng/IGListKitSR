/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <IGListKit/IGListDiffable.h>
#import <IGListKit/IGListIndexPathResult.h>
#import <IGListKit/IGListIndexSetResult.h>

NS_ASSUME_NONNULL_BEGIN

/**
 An option for how to do comparisons between similar objects.
 */
NS_SWIFT_NAME(ListDiffOption)
typedef NS_ENUM(NSInteger, IGListDiffOption) {
    /**
     指针相等性
     Compare objects using pointer personality.
     */
    IGListDiffPointerPersonality,
    /**
     抽象业务相等性
     Compare objects using `-[IGListDiffable isEqualToDiffableObject:]`.
     */
    IGListDiffEquality
};

/**
 Creates a diff using indexes between two collections.
 给定两组数据源，返回不同
 
 @param oldArray The old objects to diff against.
 @param newArray The new objects.
 @param option An option on how to compare objects.

 @return A result object containing affected indexes.
 */
NS_SWIFT_NAME(ListDiff(oldArray:newArray:option:))
FOUNDATION_EXTERN  IGListIndexSetResult *IGListDiff(NSArray<id<IGListDiffable>> *_Nullable oldArray,
                                                   NSArray<id<IGListDiffable>> *_Nullable newArray,
                                                   IGListDiffOption option);

/**
 Creates a diff using index paths between two collections.

 @param fromSection The old section.
 @param toSection The new section.
 @param oldArray The old objects to diff against.
 @param newArray The new objects.
 @param option An option on how to compare objects.

 @return A result object containing affected indexes.
 */
NS_SWIFT_NAME(ListDiffPaths(fromSection:toSection:oldArray:newArray:option:))
FOUNDATION_EXTERN IGListIndexPathResult *IGListDiffPaths(NSInteger fromSection,
                                                         NSInteger toSection,
                                                         NSArray<id<IGListDiffable>> *_Nullable oldArray,
                                                         NSArray<id<IGListDiffable>> *_Nullable newArray,
                                                         IGListDiffOption option);

NS_ASSUME_NONNULL_END
