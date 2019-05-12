/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "IGListAdapterUpdater.h"
#import "IGListAdapterUpdaterInternal.h"

#import <IGListKit/IGListAssert.h>
#import <IGListKit/IGListBatchUpdateData.h>
#import <IGListKit/IGListDiff.h>
#import <IGListKit/IGListIndexSetResultInternal.h>
#import <IGListKit/IGListMoveIndexPathInternal.h>

#import "UICollectionView+IGListBatchUpdateData.h"
#import "IGListReloadIndexPath.h"
#import "IGListArrayUtilsInternal.h"

@implementation IGListAdapterUpdater

- (instancetype)init {
    IGAssertMainThread();

    if (self = [super init]) {
        // the default is to use animations unless NO is passed
        _queuedUpdateIsAnimated = YES;
        _completionBlocks = [NSMutableArray new];
        _batchUpdates = [IGListBatchUpdates new];
        _allowsBackgroundReloading = YES;
    }
    return self;
}

#pragma mark - Private API

- (BOOL)hasChanges {
    return self.hasQueuedReloadData
    || [self.batchUpdates hasChanges]
    || self.fromObjects != nil
    || self.toObjectsBlock != nil;
}

// 执行一次全量更新
- (void)performReloadDataWithCollectionViewBlock:(IGListCollectionViewBlock)collectionViewBlock {
    IGAssertMainThread();
    
    id<IGListAdapterUpdaterDelegate> delegate = self.delegate;
    void (^reloadUpdates)(void) = self.reloadUpdates;
    // batchUpdates 标记了很多需要具体更新的 index
    IGListBatchUpdates *batchUpdates = self.batchUpdates;
    
    NSMutableArray *completionBlocks = [self.completionBlocks mutableCopy];
    
    // clear 所有和中间状态相关的变量
    [self cleanStateBeforeUpdates];
    
    // 将所有的 completion 的调用集合到一起，放在一个 block 中
    void (^executeCompletionBlocks)(BOOL) = ^(BOOL finished) {
        for (IGListUpdatingCompletion block in completionBlocks) {
            block(finished);
        }
        // 既然 update 完成了，那么就需要将状态设置为 idle ？？
        self.state = IGListBatchUpdateStateIdle;
    };

    // bail early if the collection view has been deallocated in the time since the update was queued
    UICollectionView *collectionView = collectionViewBlock();
    if (collectionView == nil) {
        // 处理在准备异步 update 时，collection view 已经被释放的 case
        [self _cleanStateAfterUpdates];
        executeCompletionBlocks(NO);
        return;
    }

    // item updates must not send mutations to the collection view while we are reloading
    self.state = IGListBatchUpdateStateExecutingBatchUpdateBlock;

    if (reloadUpdates) {
        reloadUpdates();    // update 一般都是真正的去更新数据源
    }

    // execute all stored item update blocks even if we are just calling reloadData. the actual collection view
    // mutations will be discarded, but clients are encouraged to put their actual /data/ mutations inside the
    // update block as well, so if we don't execute the block the changes will never happen
    for (IGListItemUpdateBlock itemUpdateBlock in batchUpdates.itemUpdateBlocks) {
        // reload 相当于更新了所有的 item， invoke block 表示正在更新
        itemUpdateBlock();
    }

    // add any completion blocks from item updates. added after item blocks are executed in order to capture any
    // re-entrant updates
    [completionBlocks addObjectsFromArray:batchUpdates.itemCompletionBlocks];

    self.state = IGListBatchUpdateStateExecutedBatchUpdateBlock;

    [self _cleanStateAfterUpdates];
    
    // 直接全量更新 collection view
    [delegate listAdapterUpdater:self willReloadDataWithCollectionView:collectionView];
    [collectionView reloadData];
    [collectionView.collectionViewLayout invalidateLayout];
    [collectionView layoutIfNeeded];
    [delegate listAdapterUpdater:self didReloadDataWithCollectionView:collectionView];

    executeCompletionBlocks(YES);
}
// queued 一个批量更新操作
- (void)performBatchUpdatesWithCollectionViewBlock:(IGListCollectionViewBlock)collectionViewBlock {
    IGAssertMainThread();
    IGAssert(self.state == IGListBatchUpdateStateIdle, @"Should not call batch updates when state isn't idle");

    // create local variables so we can immediately clean our state but pass these items into the batch update block
    // 使用 local 变量存储当前的 context
    id<IGListAdapterUpdaterDelegate> delegate = self.delegate;
    NSArray *fromObjects = [self.fromObjects copy];
    IGListToObjectBlock toObjectsBlock = [self.toObjectsBlock copy];
    NSMutableArray *completionBlocks = [self.completionBlocks mutableCopy];
    void (^objectTransitionBlock)(NSArray *) = [self.objectTransitionBlock copy];
    const BOOL animated = self.queuedUpdateIsAnimated;
    IGListBatchUpdates *batchUpdates = self.batchUpdates;

    // clean up all state so that new updates can be coalesced while the current update is in flight
    // 然后将 self 的属性清空，避免本次 update 时依赖的属性被污染
    [self cleanStateBeforeUpdates];

    void (^executeCompletionBlocks)(BOOL) = ^(BOOL finished) {
        // update 真正结束时调用
        self.applyingUpdateData = nil;
        self.state = IGListBatchUpdateStateIdle;

        for (IGListUpdatingCompletion block in completionBlocks) {
            block(finished);
        }
    };

    // bail early if the collection view has been deallocated in the time since the update was queued
    UICollectionView *collectionView = collectionViewBlock();
    if (collectionView == nil) {
        [self _cleanStateAfterUpdates];
        executeCompletionBlocks(NO);
        return;
    }
    
    // 得到真正更新后的数据源
    NSArray *toObjects = nil;
    if (toObjectsBlock != nil) {
        toObjects = objectsWithDuplicateIdentifiersRemoved(toObjectsBlock());
    }
#ifdef DEBUG
    for (id obj in toObjects) {
        IGAssert([obj conformsToProtocol:@protocol(IGListDiffable)],
                 @"In order to use IGListAdapterUpdater, object %@ must conform to IGListDiffable", obj);
        IGAssert([obj diffIdentifier] != nil,
                 @"Cannot have a nil diffIdentifier for object %@", obj);
    }
#endif

    // 执行更新操作
    void (^executeUpdateBlocks)(void) = ^{
        // 标记开始 update
        self.state = IGListBatchUpdateStateExecutingBatchUpdateBlock;

        // run the update block so that the adapter can set its items. this makes sure that just before the update is
        // committed that the data source is updated to the /latest/ "toObjects". this makes the data source in sync
        // with the items that the updater is transitioning to
        if (objectTransitionBlock != nil) {
            objectTransitionBlock(toObjects);
        }

        // execute each item update block which should make calls like insert, delete, and reload for index paths
        // we collect all mutations in corresponding sets on self, then filter based on UICollectionView shortcomings
        // call after the objectTransitionBlock so section level mutations happen before any items
        for (IGListItemUpdateBlock itemUpdateBlock in batchUpdates.itemUpdateBlocks) {
            itemUpdateBlock();
        }

        // add any completion blocks from item updates. added after item blocks are executed in order to capture any
        // re-entrant updates
        [completionBlocks addObjectsFromArray:batchUpdates.itemCompletionBlocks];

        self.state = IGListBatchUpdateStateExecutedBatchUpdateBlock;
    };
    
    // 更新失败
    void (^reloadDataFallback)(void) = ^{
        executeUpdateBlocks();
        [self _cleanStateAfterUpdates];
        [self _performBatchUpdatesItemBlockApplied];
        [collectionView reloadData];
        if (!IGListExperimentEnabled(self.experiments, IGListExperimentSkipLayout)
            || collectionView.window != nil) {
            [collectionView layoutIfNeeded];
        }
        executeCompletionBlocks(YES);
    };

    // if the collection view isn't in a visible window, skip diffing and batch updating. execute all transition blocks,
    // reload data, execute completion blocks, and get outta here
    const BOOL iOS83OrLater = (NSFoundationVersionNumber >= NSFoundationVersionNumber_iOS_8_3);
    if (iOS83OrLater && self.allowsBackgroundReloading && collectionView.window == nil) {
        // 8.3 之后如果可以后台更新的话，就将本次的更新后数据源保存起来
        [self _beginPerformBatchUpdatesToObjects:toObjects];
        // 宣布更新失败
        reloadDataFallback();
        return;
    }

    // disables multiple performBatchUpdates: from happening at the same time
    // 表示开始进行 update，保存起来中间状态，防止同一时间进行刷新
    [self _beginPerformBatchUpdatesToObjects:toObjects];

    const IGListExperiment experiments = self.experiments;

    // Diff block
    IGListIndexSetResult *(^performDiff)(void) = ^{
        return IGListDiffExperiment(fromObjects, toObjects, IGListDiffEquality, experiments);
    };

    // block executed in the first param block of -[UICollectionView performBatchUpdates:completion:]
    // 执行真正的 update index 操作
    void (^batchUpdatesBlock)(IGListIndexSetResult *result) = ^(IGListIndexSetResult *result){
        // 执行更新操作
        executeUpdateBlocks();
        
        // 计算得到要更新的所有操作
        self.applyingUpdateData = [self _flushCollectionView:collectionView
                                              withDiffResult:result
                                                batchUpdates:self.batchUpdates
                                                 fromObjects:fromObjects];
        
        [self _cleanStateAfterUpdates];
        // 执行所有的更新操作
        [self _performBatchUpdatesItemBlockApplied];
    };

    // block used as the second param of -[UICollectionView performBatchUpdates:completion:]
    void (^batchUpdatesCompletionBlock)(BOOL) = ^(BOOL finished) {
        // 
        IGListBatchUpdateData *oldApplyingUpdateData = self.applyingUpdateData;
        executeCompletionBlocks(finished);

        [delegate listAdapterUpdater:self didPerformBatchUpdates:oldApplyingUpdateData collectionView:collectionView];

        // queue another update in case something changed during batch updates. this method will bail next runloop if
        // there are no changes
        [self _queueUpdateWithCollectionViewBlock:collectionViewBlock];
    };

    // block that executes the batch update and exception handling
    // 最终调用这个 block 来更新 diff 之后的结果
    void (^performUpdate)(IGListIndexSetResult *) = ^(IGListIndexSetResult *result){
        // 这里为什么要先计算下布局？应该是为了之后的移动操作之类的吧
        [collectionView layoutIfNeeded];

        @try {
            // Notifies the delegate will apply batch update
            [delegate  listAdapterUpdater:self
willPerformBatchUpdatesWithCollectionView:collectionView
                              fromObjects:fromObjects
                                toObjects:toObjects
                       listIndexSetResult:result];
            if (collectionView.dataSource == nil) {
                // If the data source is nil, we should not call any collection view update.
                // 如果数据源不存在，直接 cancel 掉好了
                batchUpdatesCompletionBlock(NO);
            } else if (result.changeCount > 100 && IGListExperimentEnabled(experiments, IGListExperimentReloadDataFallback)) {
                // 如果更新的数量超过了 100 ，但是没有开启 reload fallback 实验，直接失败
                reloadDataFallback();
            }
            // 在系统的 block 中执行真正的 index 更新操作
            else if (animated) {
                [collectionView performBatchUpdates:^{
                    batchUpdatesBlock(result);
                } completion:batchUpdatesCompletionBlock];
            } else {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                [collectionView performBatchUpdates:^{
                    batchUpdatesBlock(result);
                } completion:^(BOOL finished) {
                    [CATransaction commit];
                    batchUpdatesCompletionBlock(finished);
                }];
            }
        } @catch (NSException *exception) {
            [delegate listAdapterUpdater:self
                          collectionView:collectionView
                  willCrashWithException:exception
                             fromObjects:fromObjects
                               toObjects:toObjects
                              diffResult:result
                                 updates:(id)self.applyingUpdateData];
            @throw exception;
        }
    };

    // 根据时否开启了后台更新实验，决定 queue
    dispatch_queue_t asyncQueue = nil;
    if (IGListExperimentEnabled(experiments, IGListExperimentBackgroundDiffing)) {
        asyncQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    } else if (IGListExperimentEnabled(experiments, IGListExperimentBackgroundDiffingSerial)) {
        if (_backgroundUpdateQueue == nil) {
            _backgroundUpdateQueue = dispatch_queue_create("io.github.instagram.IGListKit.backgroundupdatequeue", DISPATCH_QUEUE_SERIAL);
        }
        asyncQueue = _backgroundUpdateQueue;
    }
    // 根据 queue ，判断时否要异步操作。得到 diff 结果，然后开始用 diff result 进行 update
    if (asyncQueue) {
        dispatch_async(asyncQueue, ^{
            IGListIndexSetResult *result = performDiff();
            dispatch_async(dispatch_get_main_queue(), ^{
                performUpdate(result);
            });
        });
    } else {
        IGListIndexSetResult *result = performDiff();
        performUpdate(result);
    }
}

void convertReloadToDeleteInsert(NSMutableIndexSet *reloads,
                                 NSMutableIndexSet *deletes,
                                 NSMutableIndexSet *inserts,
                                 IGListIndexSetResult *result,
                                 NSArray<id<IGListDiffable>> *fromObjects) {
    // reloadSections: is unsafe to use within performBatchUpdates:, so instead convert all reloads into deletes+inserts
    const BOOL hasObjects = [fromObjects count] > 0;
    [[reloads copy] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        // if a diff was not performed, there are no changes. instead use the same index that was originally queued
        id<NSObject> diffIdentifier = hasObjects ? [fromObjects[idx] diffIdentifier] : nil;
        const NSInteger from = hasObjects ? [result oldIndexForIdentifier:diffIdentifier] : idx;
        const NSInteger to = hasObjects ? [result newIndexForIdentifier:diffIdentifier] : idx;
        [reloads removeIndex:from];

        // if a reload is queued outside the diff and the object was inserted or deleted it cannot be
        if (from != NSNotFound && to != NSNotFound) {
            [deletes addIndex:from];
            [inserts addIndex:to];
        } else {
            IGAssert([result.deletes containsIndex:idx],
                     @"Reloaded section %lu was not found in deletes with from: %li, to: %li, deletes: %@, fromClass: %@",
                     (unsigned long)idx, (long)from, (long)to, deletes, [(id)fromObjects[idx] class]);
        }
    }];
}

static NSArray<NSIndexPath *> *convertSectionReloadToItemUpdates(NSIndexSet *sectionReloads, UICollectionView *collectionView) {
    NSMutableArray<NSIndexPath *> *updates = [NSMutableArray new];
    [sectionReloads enumerateIndexesUsingBlock:^(NSUInteger sectionIndex, BOOL * _Nonnull stop) {
        NSUInteger numberOfItems = [collectionView numberOfItemsInSection:sectionIndex];
        for (NSUInteger itemIndex = 0; itemIndex < numberOfItems; itemIndex++) {
            [updates addObject:[NSIndexPath indexPathForItem:itemIndex inSection:sectionIndex]];
        }
    }];
    return [updates copy];
}

/**
 collection 的真正刷新工作

 @param collectionView 并没有对 collection。做特殊限制，只要是系统的就行。因此对 collection view 的调用，是可以通过子类重载的
 @param diffResult 
 @param batchUpdates
 @param fromObjects
 @return
 */
- (IGListBatchUpdateData *)_flushCollectionView:(UICollectionView *)collectionView
                                withDiffResult:(IGListIndexSetResult *)diffResult
                                  batchUpdates:(IGListBatchUpdates *)batchUpdates
                                   fromObjects:(NSArray <id<IGListDiffable>> *)fromObjects {
    NSSet *moves = [[NSSet alloc] initWithArray:diffResult.moves];

    // combine section reloads from the diff and manual reloads via reloadItems:
    NSMutableIndexSet *reloads = [diffResult.updates mutableCopy];
    [reloads addIndexes:batchUpdates.sectionReloads];

    NSMutableIndexSet *inserts = [diffResult.inserts mutableCopy];
    NSMutableIndexSet *deletes = [diffResult.deletes mutableCopy];
    NSMutableArray<NSIndexPath *> *itemUpdates = [NSMutableArray new];
    if (self.movesAsDeletesInserts) {
        for (IGListMoveIndex *move in moves) {
            [deletes addIndex:move.from];
            [inserts addIndex:move.to];
        }
        // clear out all moves
        moves = [NSSet new];
    }

    // Item reloads are not safe, if any section moves happened or there are inserts/deletes.
    if (self.preferItemReloadsForSectionReloads
        && moves.count == 0 && inserts.count == 0 && deletes.count == 0 && reloads.count > 0) {
        [reloads enumerateIndexesUsingBlock:^(NSUInteger sectionIndex, BOOL * _Nonnull stop) {
            NSMutableIndexSet *localIndexSet = [NSMutableIndexSet indexSetWithIndex:sectionIndex];
            if (sectionIndex < [collectionView numberOfSections]
                && sectionIndex < [collectionView.dataSource numberOfSectionsInCollectionView:collectionView]
                && [collectionView numberOfItemsInSection:sectionIndex] == [collectionView.dataSource collectionView:collectionView numberOfItemsInSection:sectionIndex]) {
                // Perfer to do item reloads instead, if the number of items in section is unchanged.
                [itemUpdates addObjectsFromArray:convertSectionReloadToItemUpdates(localIndexSet, collectionView)];
            } else {
                // Otherwise, fallback to convert into delete+insert section operation.
                convertReloadToDeleteInsert(localIndexSet, deletes, inserts, diffResult, fromObjects);
            }
        }];
    } else {
        // reloadSections: is unsafe to use within performBatchUpdates:, so instead convert all reloads into deletes+inserts
        convertReloadToDeleteInsert(reloads, deletes, inserts, diffResult, fromObjects);
    }
    
    NSMutableArray<NSIndexPath *> *itemInserts = batchUpdates.itemInserts;
    NSMutableArray<NSIndexPath *> *itemDeletes = batchUpdates.itemDeletes;
    NSMutableArray<IGListMoveIndexPath *> *itemMoves = batchUpdates.itemMoves;

    NSSet<NSIndexPath *> *uniqueDeletes = [NSSet setWithArray:itemDeletes];
    NSMutableSet<NSIndexPath *> *reloadDeletePaths = [NSMutableSet new];
    NSMutableSet<NSIndexPath *> *reloadInsertPaths = [NSMutableSet new];
    for (IGListReloadIndexPath *reload in batchUpdates.itemReloads) {
        if (![uniqueDeletes containsObject:reload.fromIndexPath]) {
            [reloadDeletePaths addObject:reload.fromIndexPath];
            [reloadInsertPaths addObject:reload.toIndexPath];
        }
    }
    [itemDeletes addObjectsFromArray:[reloadDeletePaths allObjects]];
    [itemInserts addObjectsFromArray:[reloadInsertPaths allObjects]];

    // 这里组装完成本次数据更新 要导致 view 的变动
    IGListBatchUpdateData *updateData = [[IGListBatchUpdateData alloc] initWithInsertSections:inserts
                                                                               deleteSections:deletes
                                                                                 moveSections:moves
                                                                             insertIndexPaths:itemInserts
                                                                             deleteIndexPaths:itemDeletes
                                                                             updateIndexPaths:itemUpdates
                                                                               moveIndexPaths:itemMoves];
    [collectionView ig_applyBatchUpdateData:updateData];
    return updateData;
}

- (void)_beginPerformBatchUpdatesToObjects:(NSArray *)toObjects {
    self.pendingTransitionToObjects = toObjects;
    self.state = IGListBatchUpdateStateQueuedBatchUpdate;
}

- (void)_performBatchUpdatesItemBlockApplied {
    self.pendingTransitionToObjects = nil;
}

- (void)cleanStateBeforeUpdates {
    self.queuedUpdateIsAnimated = YES;

    // destroy to/from transition items
    self.fromObjects = nil;
    self.toObjectsBlock = nil;

    // destroy reloadData state
    self.reloadUpdates = nil;
    self.queuedReloadData = NO;

    // remove indexpath/item changes
    self.objectTransitionBlock = nil;

    // removes all object completion blocks. done before updates to start collecting completion blocks for coalesced
    // or re-entrant object updates
    [self.completionBlocks removeAllObjects];
}

- (void)_cleanStateAfterUpdates {
    self.batchUpdates = [IGListBatchUpdates new];
}

- (void)_queueUpdateWithCollectionViewBlock:(IGListCollectionViewBlock)collectionViewBlock {
    IGAssertMainThread();
    
    __weak __typeof__(self) weakSelf = self;
    
    // dispatch_async to give the main queue time to collect more batch updates so that a minimum amount of work
    // (diffing, etc) is done on main. dispatch_async does not garauntee a full runloop turn will pass though.
    // see -performUpdateWithCollectionView:fromObjects:toObjects:animated:objectTransitionBlock:completion: for more
    // details on how coalescence is done.
    /**
     将本次的 update 加入到主队列中，这样可以保证在一次 runloop 中尽可能收集到更多的 update ，并进行一次处理
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.state != IGListBatchUpdateStateIdle
            || ![weakSelf hasChanges]) {
            // 批量更新被暂停，并且最终没有更改发生，直接 return ,一般是因为调用了 executeCompletionBlocks 导致
            return;
        }
        // 如果批量更新的过程中，有一次调用了 reload 全量更新，那么直接使用 reload
        if (weakSelf.hasQueuedReloadData) {
            [weakSelf performReloadDataWithCollectionViewBlock:collectionViewBlock];
        } else {
            [weakSelf performBatchUpdatesWithCollectionViewBlock:collectionViewBlock];
        }
    });
}


#pragma mark - IGListUpdatingDelegate

static BOOL IGListIsEqual(const void *a, const void *b, NSUInteger (*size)(const void *item)) {
    const id<IGListDiffable, NSObject> left = (__bridge id<IGListDiffable, NSObject>)a;
    const id<IGListDiffable, NSObject> right = (__bridge id<IGListDiffable, NSObject>)b;
    return [left class] == [right class]
    && [[left diffIdentifier] isEqual:[right diffIdentifier]];
}

// since the diffing algo used in this updater keys items based on their -diffIdentifier, we must use a map table that
// precisely mimics this behavior
static NSUInteger IGListIdentifierHash(const void *item, NSUInteger (*size)(const void *item)) {
    return [[(__bridge id<IGListDiffable>)item diffIdentifier] hash];
}

- (NSPointerFunctions *)objectLookupPointerFunctions {
    NSPointerFunctions *functions = [NSPointerFunctions pointerFunctionsWithOptions:NSPointerFunctionsStrongMemory];
    functions.hashFunction = IGListIdentifierHash;
    functions.isEqualFunction = IGListIsEqual;
    return functions;
}
// 执行真正的 collection view update
- (void)performUpdateWithCollectionViewBlock:(IGListCollectionViewBlock)collectionViewBlock
                            fromObjects:(NSArray *)fromObjects
                         toObjectsBlock:(IGListToObjectBlock)toObjectsBlock
                               animated:(BOOL)animated
                  objectTransitionBlock:(IGListObjectTransitionBlock)objectTransitionBlock
                             completion:(IGListUpdatingCompletion)completion {
    IGAssertMainThread();
    IGParameterAssert(collectionViewBlock != nil);
    IGParameterAssert(objectTransitionBlock != nil);

    // only update the items that we are coming from if it has not been set
    // this allows multiple updates to be called while an update is already in progress, and the transition from > to
    // will be done on the first "fromObjects" received and the last "toObjects"
    // if performBatchUpdates: hasn't applied the update block, then data source hasn't transitioned its state. if an
    // update is queued in between then we must use the pending toObjects
    // 如果本次调用之前已经处于 update 过程中，那么还是用之前的 origin bobjects
    self.fromObjects = self.fromObjects ?: self.pendingTransitionToObjects ?: fromObjects;
    self.toObjectsBlock = toObjectsBlock;

    // disabled animations will always take priority
    // reset to YES in -cleanupState
    self.queuedUpdateIsAnimated = self.queuedUpdateIsAnimated && animated;

    // always use the last update block, even though this should always do the exact same thing
    self.objectTransitionBlock = objectTransitionBlock;

    IGListUpdatingCompletion localCompletion = completion;
    if (localCompletion) {
        // 将本次的 completion 加入，之后真正 update 完成的时候，要调用
        [self.completionBlocks addObject:localCompletion];
    }
    // 加入到 update 的队列中
    [self _queueUpdateWithCollectionViewBlock:collectionViewBlock];
}

- (void)performUpdateWithCollectionViewBlock:(IGListCollectionViewBlock)collectionViewBlock
                               animated:(BOOL)animated
                            itemUpdates:(void (^)(void))itemUpdates
                             completion:(void (^)(BOOL))completion {
    IGAssertMainThread();
    IGParameterAssert(collectionViewBlock != nil);
    IGParameterAssert(itemUpdates != nil);

    IGListBatchUpdates *batchUpdates = self.batchUpdates;
    if (completion != nil) {
        [batchUpdates.itemCompletionBlocks addObject:completion];
    }

    // if already inside the execution of the update block, immediately unload the itemUpdates block.
    // the completion blocks are executed later in the lifecycle, so that still needs to be added to the batch
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        itemUpdates();
    } else {
        [batchUpdates.itemUpdateBlocks addObject:itemUpdates];

        // disabled animations will always take priority
        // reset to YES in -cleanupState
        self.queuedUpdateIsAnimated = self.queuedUpdateIsAnimated && animated;

        [self _queueUpdateWithCollectionViewBlock:collectionViewBlock];
    }
}

- (void)insertItemsIntoCollectionView:(UICollectionView *)collectionView indexPaths:(NSArray <NSIndexPath *> *)indexPaths {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(indexPaths != nil);
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        [self.batchUpdates.itemInserts addObjectsFromArray:indexPaths];
    } else {
        [self.delegate listAdapterUpdater:self willInsertIndexPaths:indexPaths collectionView:collectionView];
        [collectionView insertItemsAtIndexPaths:indexPaths];
    }
}

- (void)deleteItemsFromCollectionView:(UICollectionView *)collectionView indexPaths:(NSArray <NSIndexPath *> *)indexPaths {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(indexPaths != nil);
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        [self.batchUpdates.itemDeletes addObjectsFromArray:indexPaths];
    } else {
        [self.delegate listAdapterUpdater:self willDeleteIndexPaths:indexPaths collectionView:collectionView];
        [collectionView deleteItemsAtIndexPaths:indexPaths];
    }
}

- (void)moveItemInCollectionView:(UICollectionView *)collectionView
                   fromIndexPath:(NSIndexPath *)fromIndexPath
                     toIndexPath:(NSIndexPath *)toIndexPath {
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        IGListMoveIndexPath *move = [[IGListMoveIndexPath alloc] initWithFrom:fromIndexPath to:toIndexPath];
        [self.batchUpdates.itemMoves addObject:move];
    } else {
        [self.delegate listAdapterUpdater:self willMoveFromIndexPath:fromIndexPath toIndexPath:toIndexPath collectionView:collectionView];
        [collectionView moveItemAtIndexPath:fromIndexPath toIndexPath:toIndexPath];
    }
}

- (void)reloadItemInCollectionView:(UICollectionView *)collectionView
                     fromIndexPath:(NSIndexPath *)fromIndexPath
                       toIndexPath:(NSIndexPath *)toIndexPath {
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        IGListReloadIndexPath *reload = [[IGListReloadIndexPath alloc] initWithFromIndexPath:fromIndexPath toIndexPath:toIndexPath];
        [self.batchUpdates.itemReloads addObject:reload];
    } else {
        [self.delegate listAdapterUpdater:self willReloadIndexPaths:@[fromIndexPath] collectionView:collectionView];
        [collectionView reloadItemsAtIndexPaths:@[fromIndexPath]];
    }
}
    
- (void)moveSectionInCollectionView:(UICollectionView *)collectionView
                          fromIndex:(NSInteger)fromIndex
                            toIndex:(NSInteger)toIndex {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);

    // iOS expects interactive reordering to be movement of items not sections
    // after moving a single-item section controller,
    // you end up with two items in the section for the drop location,
    // and zero items in the section originating at the drag location
    // so, we have to reload data rather than doing a section move

    [collectionView reloadData];

    // It seems that reloadData called during UICollectionView's moveItemAtIndexPath
    // delegate call does not reload all cells as intended
    // So, we further reload all visible sections to make sure none of our cells
    // are left with data that's out of sync with our dataSource
    
    id<IGListAdapterUpdaterDelegate> delegate = self.delegate;
    
    NSMutableIndexSet *visibleSections = [NSMutableIndexSet new];
    NSArray *visibleIndexPaths = [collectionView indexPathsForVisibleItems];
    for (NSIndexPath *visibleIndexPath in visibleIndexPaths) {
        [visibleSections addIndex:visibleIndexPath.section];
    }
    
    [delegate listAdapterUpdater:self willReloadSections:visibleSections collectionView:collectionView];
    
    // prevent double-animation from reloadData + reloadSections
    
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [collectionView performBatchUpdates:^{
        [collectionView reloadSections:visibleSections];
    } completion:^(BOOL finished) {
        [CATransaction commit];
    }];
}

- (void)reloadDataWithCollectionViewBlock:(IGListCollectionViewBlock)collectionViewBlock
                   reloadUpdateBlock:(IGListReloadUpdateBlock)reloadUpdateBlock
                          completion:(nullable IGListUpdatingCompletion)completion {
    IGAssertMainThread();
    IGParameterAssert(collectionViewBlock != nil);
    IGParameterAssert(reloadUpdateBlock != nil);

    IGListUpdatingCompletion localCompletion = completion;
    if (localCompletion) {
        [self.completionBlocks addObject:localCompletion];
    }

    self.reloadUpdates = reloadUpdateBlock;
    self.queuedReloadData = YES;
    [self _queueUpdateWithCollectionViewBlock:collectionViewBlock];
}

- (void)reloadCollectionView:(UICollectionView *)collectionView sections:(NSIndexSet *)sections {
    IGAssertMainThread();
    IGParameterAssert(collectionView != nil);
    IGParameterAssert(sections != nil);
    if (self.state == IGListBatchUpdateStateExecutingBatchUpdateBlock) {
        [self.batchUpdates.sectionReloads addIndexes:sections];
    } else {
        [self.delegate listAdapterUpdater:self willReloadSections:sections collectionView:collectionView];
        [collectionView reloadSections:sections];
    }
}


@end

