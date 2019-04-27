/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "IGListSectionMap.h"

#import <IGListKit/IGListAssert.h>

#import "IGListSectionControllerInternal.h"

@interface IGListSectionMap ()

// both of these maps allow fast lookups of objects, list objects, and indexes
@property (nonatomic, strong, readonly, nonnull) NSMapTable<id, IGListSectionController *> *objectToSectionControllerMap;
@property (nonatomic, strong, readonly, nonnull) NSMapTable<IGListSectionController *, NSNumber *> *sectionControllerToSectionMap;

@property (nonatomic, strong, nonnull) NSMutableArray *mObjects;

@end

@implementation IGListSectionMap

- (instancetype)initWithMapTable:(NSMapTable *)mapTable {
    IGParameterAssert(mapTable != nil);

    if (self = [super init]) {
        
        // key = section ,value = controller
        _objectToSectionControllerMap = [mapTable copy];

        // lookup list objects by pointer equality
        
        // value = 原始 object，比如 LiveModel ,key = controller
        _sectionControllerToSectionMap = [[NSMapTable alloc] initWithKeyOptions:NSMapTableStrongMemory | NSMapTableObjectPointerPersonality
                                                                   valueOptions:NSMapTableStrongMemory
                                                                        capacity:0];
        /*  NSMapTableObjectPointerPersonality 可以根据内存地址进行比较时否相等
         *
         */
        // 存储真正的 controller 对象
        _mObjects = [NSMutableArray new];
    }
    return self;
}


#pragma mark - Public API

- (NSArray *)objects {
    return [self.mObjects copy];
}

// 根据 controller 得到 section index
- (NSInteger)sectionForSectionController:(IGListSectionController *)sectionController {
    IGParameterAssert(sectionController != nil);
    
    // 直接通过 Map 即可拿到 controller 对应的 section idx
    NSNumber *index = [self.sectionControllerToSectionMap objectForKey:sectionController];
    return index != nil ? [index integerValue] : NSNotFound;
}

// 根据 section 得到 controller
- (IGListSectionController *)sectionControllerForSection:(NSInteger)section {
    return [self.objectToSectionControllerMap objectForKey:[self objectForSection:section]];
}

// 更新 section 和 controller
- (void)updateWithObjects:(NSArray *)objects sectionControllers:(NSArray *)sectionControllers {
    IGParameterAssert(objects.count == sectionControllers.count);

    [self reset];

    // mObject 存储所有的原始数据源信息
    self.mObjects = [objects mutableCopy];

    id firstObject = objects.firstObject;
    id lastObject = objects.lastObject;

    [objects enumerateObjectsUsingBlock:^(id object, NSUInteger idx, BOOL *stop) {
        IGListSectionController *sectionController = sectionControllers[idx];

        // set the index of the list for easy reverse lookup
        [self.sectionControllerToSectionMap setObject:@(idx) forKey:sectionController];
        
        // section controller 与 原始 object 对应起来
        [self.objectToSectionControllerMap setObject:sectionController forKey:object];
        
        // 判断时否为 first or last。之后有用 TODO
        sectionController.isFirstSection = (object == firstObject);
        sectionController.isLastSection = (object == lastObject);
        sectionController.section = (NSInteger)idx;
    }];
}

- (nullable IGListSectionController *)sectionControllerForObject:(id)object {
    IGParameterAssert(object != nil);

    return [self.objectToSectionControllerMap objectForKey:object];
}

- (nullable id)objectForSection:(NSInteger)section {
    NSArray *objects = self.mObjects;
    if (section < objects.count) {
        return objects[section];
    } else {
        return nil;
    }
}

- (NSInteger)sectionForObject:(id)object {
    IGParameterAssert(object != nil);

    id sectionController = [self sectionControllerForObject:object];
    if (sectionController == nil) {
        return NSNotFound;
    } else {
        return [self sectionForSectionController:sectionController];
    }
}

- (void)reset {
    
    // Clear 每一个 controller 然后删除所有的 controller ，防止内存泄漏
    // 比如内部的 section 被其他 class 持有
    [self enumerateUsingBlock:^(id  _Nonnull object, IGListSectionController * _Nonnull sectionController, NSInteger section, BOOL * _Nonnull stop) {
        sectionController.section = NSNotFound;
        sectionController.isFirstSection = NO;
        sectionController.isLastSection = NO;
    }];

    [self.sectionControllerToSectionMap removeAllObjects];
    [self.objectToSectionControllerMap removeAllObjects];
}

- (void)updateObject:(id)object {
    IGParameterAssert(object != nil);
    const NSInteger section = [self sectionForObject:object];
    id sectionController = [self sectionControllerForObject:object];
    [self.sectionControllerToSectionMap setObject:@(section) forKey:sectionController];
    [self.objectToSectionControllerMap setObject:sectionController forKey:object];
    self.mObjects[section] = object;
}

- (void)enumerateUsingBlock:(void (^)(id object, IGListSectionController *sectionController, NSInteger section, BOOL *stop))block {
    IGParameterAssert(block != nil);

    BOOL stop = NO;
    NSArray *objects = self.objects;
    for (NSInteger section = 0; section < objects.count; section++) {
        id object = objects[section];
        IGListSectionController *sectionController = [self sectionControllerForObject:object];
        block(object, sectionController, section, &stop);
        if (stop) {
            break;
        }
    }
}


#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    IGListSectionMap *copy = [[IGListSectionMap allocWithZone:zone] initWithMapTable:self.objectToSectionControllerMap];
    if (copy != nil) {
        copy->_sectionControllerToSectionMap = [self.sectionControllerToSectionMap copy];
        copy->_mObjects = [self.mObjects mutableCopy];
    }
    return copy;
}

@end
