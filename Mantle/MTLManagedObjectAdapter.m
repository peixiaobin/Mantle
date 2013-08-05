//
//  MTLManagedObjectAdapter.m
//  Mantle
//
//  Created by Justin Spahr-Summers on 2013-03-29.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "MTLManagedObjectAdapter.h"
#import "EXTScope.h"
#import "MTLModel.h"
#import "MTLReflection.h"

NSString * const MTLRelationshipModelTransformerContext = @"MTLRelationshipModelTransformerContext";
NSString * const MTLRelationshipModelTransfomerModel = @"MTLRelationshipModelTransfomerModel";

NSString * const MTLManagedObjectAdapterErrorDomain = @"MTLManagedObjectAdapterErrorDomain";
const NSInteger MTLManagedObjectAdapterErrorNoClassFound = 2;
const NSInteger MTLManagedObjectAdapterErrorInitializationFailed = 3;
const NSInteger MTLManagedObjectAdapterErrorInvalidManagedObjectKey = 4;
const NSInteger MTLManagedObjectAdapterErrorUnsupportedManagedObjectPropertyType = 5;
const NSInteger MTLManagedObjectAdapterErrorUnsupportedRelationshipClass = 6;

// Performs the given block in the context's queue, if it has one.
static id performInContext(NSManagedObjectContext *context, id (^block)(void)) {
	if (context.concurrencyType == NSConfinementConcurrencyType) {
		return block();
	}

	__block id result = nil;
	[context performBlockAndWait:^{
		result = block();
	}];

	return result;
}

// An exception was thrown and caught.
static const NSInteger MTLManagedObjectAdapterErrorExceptionThrown = 1;

@interface MTLManagedObjectAdapter ()

// The MTLModel subclass being serialized or deserialized.
@property (nonatomic, strong, readonly) Class modelClass;

// A cached copy of the return value of +managedObjectKeysByPropertyKey.
@property (nonatomic, copy, readonly) NSDictionary *managedObjectKeysByPropertyKey;

// A cached copy of the return value of +relationshipModelClassesByPropertyKey.
@property (nonatomic, copy, readonly) NSDictionary *relationshipModelClassesByPropertyKey;

// Initializes the receiver to serialize or deserialize a MTLModel of the given
// class.
- (id)initWithModelClass:(Class)modelClass;

// Invoked from +modelOfClass:fromManagedObject:processedObjects:error: after
// the receiver's properties have been initialized.
- (id)modelFromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error;

// Performs the actual work of deserialization. This method is also invoked when
// processing relationships, to create a new adapter (if needed) to handle them.
//
// `processedObjects` is a dictionary mapping NSManagedObjects to the MTLModels
// that have been created so far. It should remain alive for the full process
// of deserializing the top-level managed object.
+ (id)modelOfClass:(Class)modelClass fromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error;

// Invoked from
// +managedObjectFromModel:insertingIntoContext:processedObjects:error: after
// the receiver's properties have been initialized.
- (NSManagedObject *)managedObjectFromModel:(MTLModel<MTLManagedObjectSerializing> *)model insertingIntoContext:(NSManagedObjectContext *)context processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error;

// Performs the actual work of serialization. This method is also invoked when
// processing relationships, to create a new adapter (if needed) to handle them.
//
// `processedObjects` is a dictionary mapping MTLModels to the NSManagedObjects
// that have been created so far. It should remain alive for the full process
// of serializing the top-level MTLModel.
+ (NSManagedObject *)managedObjectFromModel:(MTLModel<MTLManagedObjectSerializing> *)model insertingIntoContext:(NSManagedObjectContext *)context processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error;

// Looks up the NSValueTransformer that should be used for any attribute that
// corresponds the given property key.
//
// key - The property key to transform from or to. This argument must not be nil.
//
// Returns a transformer to use, or nil to not transform the property.
- (NSValueTransformer *)entityAttributeTransformerForKey:(NSString *)key;

// Looks up the NSValueTransformer that should be used for any attribute that
// corresponds the given relationship key.
//
// key - The property key for the relationship to transform from or to. This argument must
// not be nil.
//
// Returns a transformer to use, or nil to not transform the property.
- (NSValueTransformer *)relationshipModelTransformerForKey:(NSString *)key;

// Looks up the managed object key that corresponds to the given key.
//
// key - The property key to retrieve the corresponding managed object key for.
//       This argument must not be nil.
//
// Returns a key to use, or nil to omit the property from managed object
// serialization.
- (NSString *)managedObjectKeyForKey:(NSString *)key;

@end

@implementation MTLManagedObjectAdapter

#pragma mark Lifecycle

- (id)init {
	NSAssert(NO, @"%@ should not be initialized using -init", self.class);
	return nil;
}

- (id)initWithModelClass:(Class)modelClass {
	NSParameterAssert(modelClass != nil);

	self = [super init];
	if (self == nil) return nil;

	_modelClass = modelClass;
	_managedObjectKeysByPropertyKey = [[modelClass managedObjectKeysByPropertyKey] copy];

	if ([modelClass respondsToSelector:@selector(relationshipModelClassesByPropertyKey)]) {
		_relationshipModelClassesByPropertyKey = [[modelClass relationshipModelClassesByPropertyKey] copy];
	}

	return self;
}

#pragma mark Serialization

- (id)modelFromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error {
	NSParameterAssert(managedObject != nil);
	NSParameterAssert(processedObjects != nil);

	NSEntityDescription *entity = managedObject.entity;
	NSAssert(entity != nil, @"%@ returned a nil +entity", managedObject);

	NSManagedObjectContext *context = managedObject.managedObjectContext;

	NSDictionary *managedObjectProperties = entity.propertiesByName;
	MTLModel *model = [[self.modelClass alloc] init];

	// Pre-emptively consider this object processed, so that we don't get into
	// any cycles when processing its relationships.
	CFDictionaryAddValue(processedObjects, (__bridge void *)managedObject, (__bridge void *)model);

	BOOL (^setValueForKey)(NSString *, id) = ^(NSString *key, id value) {
		// Mark this as being autoreleased, because validateValue may return
		// a new object to be stored in this variable (and we don't want ARC to
		// double-free or leak the old or new values).
		__autoreleasing id replaceableValue = value;
		if (![model validateValue:&replaceableValue forKey:key error:error]) return NO;

		[model setValue:replaceableValue forKey:key];
		return YES;
	};

	for (NSString *propertyKey in [self.modelClass propertyKeys]) {
		NSString *managedObjectKey = [self managedObjectKeyForKey:propertyKey];
		if (managedObjectKey == nil) continue;

		BOOL (^deserializeAttribute)(NSAttributeDescription *) = ^(NSAttributeDescription *attributeDescription) {
			id value = performInContext(context, ^{
				return [managedObject valueForKey:managedObjectKey];
			});

			NSValueTransformer *attributeTransformer = [self entityAttributeTransformerForKey:propertyKey];
			if (attributeTransformer != nil) value = [attributeTransformer reverseTransformedValue:value];

			return setValueForKey(propertyKey, value);
		};

		BOOL (^deserializeRelationship)(NSRelationshipDescription *) = ^(NSRelationshipDescription *relationshipDescription) {
			Class nestedClass = self.relationshipModelClassesByPropertyKey[propertyKey];
			if (nestedClass == nil) {
				[NSException raise:NSInvalidArgumentException format:@"No class specified for decoding relationship at key \"%@\" in managed object %@", managedObjectKey, managedObject];
			}

			if ([relationshipDescription isToMany]) {
				id models = performInContext(context, ^ id {
					id relationshipCollection = [managedObject valueForKey:managedObjectKey];
					NSMutableArray *models = [NSMutableArray arrayWithCapacity:[relationshipCollection count]];

					for (NSManagedObject *nestedObject in relationshipCollection) {
                        NSValueTransformer *attributeTransformer = [self relationshipModelTransformerForKey:propertyKey];
                        MTLModel *model = nil;
                        
                        if (attributeTransformer != nil) model = [attributeTransformer reverseTransformedValue:nestedObject];
                        if (!model || ![model isKindOfClass:[MTLModel class]]) model = [self.class modelOfClass:nestedClass fromManagedObject:nestedObject processedObjects:processedObjects error:error];
                        
						if (model == nil) return nil;
						
						[models addObject:model];
					}

					return models;
				});

				if (models == nil) return NO;
				if (![relationshipDescription isOrdered]) models = [NSSet setWithArray:models];

				return setValueForKey(propertyKey, models);
			} else {
				NSManagedObject *nestedObject = performInContext(context, ^{
					return [managedObject valueForKey:managedObjectKey];
				});

				if (nestedObject == nil) return YES;

                NSValueTransformer *attributeTransformer = [self relationshipModelTransformerForKey:propertyKey];
                MTLModel *model = nil;
                if (attributeTransformer != nil) model = [attributeTransformer reverseTransformedValue:nestedObject];
                if (!model || ![model isKindOfClass:[MTLModel class]]) model = [self.class modelOfClass:nestedClass fromManagedObject:nestedObject processedObjects:processedObjects error:error];
                
				if (model == nil) return NO;

				return setValueForKey(propertyKey, model);
			}
		};

		BOOL (^deserializeProperty)(NSPropertyDescription *) = ^(NSPropertyDescription *propertyDescription) {
			if (propertyDescription == nil) {
				if (error != NULL) {
					NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"No property by name \"%@\" exists on the entity.", @""), managedObjectKey];

					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not deserialize managed object", @""),
						NSLocalizedFailureReasonErrorKey: failureReason,
					};

					*error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorInvalidManagedObjectKey userInfo:userInfo];
				}

				return NO;
			}

			// Jump through some hoops to avoid referencing classes directly.
			NSString *propertyClassName = NSStringFromClass(propertyDescription.class);
			if ([propertyClassName isEqual:@"NSAttributeDescription"]) {
				return deserializeAttribute((id)propertyDescription);
			} else if ([propertyClassName isEqual:@"NSRelationshipDescription"]) {
				return deserializeRelationship((id)propertyDescription);
			} else {
				if (error != NULL) {
					NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property descriptions of class %@ are unsupported.", @""), propertyClassName];

					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not deserialize managed object", @""),
						NSLocalizedFailureReasonErrorKey: failureReason,
					};

					*error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorUnsupportedManagedObjectPropertyType userInfo:userInfo];
				}

				return NO;
			}
		};

		if (!deserializeProperty(managedObjectProperties[managedObjectKey])) return nil;
	}

	return model;
}

+ (id)modelOfClass:(Class)modelClass fromManagedObject:(NSManagedObject *)managedObject error:(NSError **)error {
	CFMutableDictionaryRef processedObjects = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	if (processedObjects == NULL) return nil;

	@onExit {
		CFRelease(processedObjects);
	};

	return [self modelOfClass:modelClass fromManagedObject:managedObject processedObjects:processedObjects error:error];
}

+ (id)modelOfClass:(Class)modelClass fromManagedObject:(NSManagedObject *)managedObject processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error {
	NSParameterAssert(modelClass != nil);
	NSParameterAssert(processedObjects != nil);

	if (managedObject == nil) return nil;

	const void *existingModel = CFDictionaryGetValue(processedObjects, (__bridge void *)managedObject);
	if (existingModel != NULL) {
		return (__bridge id)existingModel;
	}

	if ([modelClass respondsToSelector:@selector(classForDeserializingManagedObject:)]) {
		modelClass = [modelClass classForDeserializingManagedObject:managedObject];
		if (modelClass == nil) {
			if (error != NULL) {
				NSDictionary *userInfo = @{
					NSLocalizedDescriptionKey: NSLocalizedString(@"Could not deserialize managed object", @""),
					NSLocalizedFailureReasonErrorKey: NSLocalizedString(@"No model class could be found to deserialize the object.", @"")
				};

				*error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorNoClassFound userInfo:userInfo];
			}

			return nil;
		}
	}

	MTLManagedObjectAdapter *adapter = [[self alloc] initWithModelClass:modelClass];
	return [adapter modelFromManagedObject:managedObject processedObjects:processedObjects error:error];
}

- (NSManagedObject *)managedObjectFromModel:(MTLModel<MTLManagedObjectSerializing> *)model insertingIntoContext:(NSManagedObjectContext *)context processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error {
	NSParameterAssert(model != nil);
	NSParameterAssert(context != nil);
	NSParameterAssert(processedObjects != nil);

	NSString *entityName = [model.class managedObjectEntityName];
	NSAssert(entityName != nil, @"%@ returned a nil +managedObjectEntityName", model.class);

	Class entityDescriptionClass = NSClassFromString(@"NSEntityDescription");
	NSAssert(entityDescriptionClass != nil, @"CoreData.framework must be linked to use MTLManagedObjectAdapter");

    // If a uniquing predicate is provided, perform a fetch request to guarentee a unique managed object.
    __block NSManagedObject *managedObject = nil;
    NSPredicate *uniquingPredicate = nil;
    if ([model respondsToSelector:@selector(managedObjectUniquingPredicate)]) {
        uniquingPredicate = model.managedObjectUniquingPredicate;
    }
    
    NSArray *results = nil;
    if (uniquingPredicate) {
        NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
        fetchRequest.entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:context];
        fetchRequest.predicate = uniquingPredicate;
        fetchRequest.fetchLimit = 20;
        
        results = [context executeFetchRequest:fetchRequest error:error];
    }
    
    if (results && results.count > 0) {
        managedObject = [results objectAtIndex:0];
    } else {
        managedObject = [entityDescriptionClass insertNewObjectForEntityForName:entityName inManagedObjectContext:context];
    }
    
	if (managedObject == nil) {
		if (error != NULL) {
			NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Failed to initialize a managed object from entity named \"%@\".", @""), entityName];

			NSDictionary *userInfo = @{
				NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
				NSLocalizedFailureReasonErrorKey: failureReason,
			};

			*error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorInitializationFailed userInfo:userInfo];
		}

		return nil;
	}

	// Pre-emptively consider this object processed, so that we don't get into
	// any cycles when processing its relationships.
	CFDictionaryAddValue(processedObjects, (__bridge void *)model, (__bridge void *)managedObject);

	NSDictionary *dictionaryValue = model.dictionaryValue;
	NSDictionary *managedObjectProperties = managedObject.entity.propertiesByName;

	[dictionaryValue enumerateKeysAndObjectsUsingBlock:^(NSString *propertyKey, id value, BOOL *stop) {
		NSString *managedObjectKey = [self managedObjectKeyForKey:propertyKey];
		if (managedObjectKey == nil) return;
		if ([value isEqual:NSNull.null]) value = nil;

		BOOL (^serializeAttribute)(NSAttributeDescription *) = ^(NSAttributeDescription *attributeDescription) {
			// Mark this as being autoreleased, because validateValue may return
			// a new object to be stored in this variable (and we don't want ARC to
			// double-free or leak the old or new values).
			__autoreleasing id transformedValue = value;

			NSValueTransformer *attributeTransformer = [self entityAttributeTransformerForKey:propertyKey];
			if (attributeTransformer != nil) transformedValue = [attributeTransformer transformedValue:transformedValue];

			if (![managedObject validateValue:&transformedValue forKey:managedObjectKey error:error]) return NO;
			[managedObject setValue:transformedValue forKey:managedObjectKey];

			return YES;
		};

		NSManagedObject * (^objectForRelationshipFromModel)(id) = ^ id (id model) {
			if (![model isKindOfClass:MTLModel.class] || ![model conformsToProtocol:@protocol(MTLManagedObjectSerializing)]) {
				if (error != NULL) {
					NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property of class %@ cannot be encoded into an NSManagedObject.", @""), [model class]];

					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
						NSLocalizedFailureReasonErrorKey: failureReason,
					};

					*error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorUnsupportedRelationshipClass userInfo:userInfo];
				}

				return nil;
			}
            
            // Mark this as being autoreleased, because validateValue may return
			// a new object to be stored in this variable (and we don't want ARC to
			// double-free or leak the old or new values).
			__autoreleasing id transformedValue = nil;
            
            NSDictionary *userDictionary = @{
                MTLRelationshipModelTransformerContext: context,
                MTLRelationshipModelTransfomerModel: model
            };
            
            NSValueTransformer *attributeTransformer = [self relationshipModelTransformerForKey:propertyKey];
			if (attributeTransformer != nil) transformedValue = [attributeTransformer transformedValue:userDictionary];
            
			if ([transformedValue isKindOfClass:[NSManagedObject class]]){
                NSString *entityName = [[model class] managedObjectEntityName];
                NSAssert(entityName != nil, @"%@ returned a nil +managedObjectEntityName", [model class]);
                
                NSEntityDescription *entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:context];
                NSAssert(entity != nil, @"Context is does not contain entities for name: %@", entityName);
                
                if (![transformedValue isKindOfClass:NSClassFromString([entity managedObjectClassName])]) {
                    [context deleteObject:transformedValue];
                } else {
                    // Pre-emptively consider this object processed, so that we don't get into
                    // any cycles when processing its relationships.
                    CFDictionaryAddValue(processedObjects, (__bridge void *)model, (__bridge void *)transformedValue);
                    return transformedValue;
                }
            }

			return [self.class managedObjectFromModel:model insertingIntoContext:context processedObjects:processedObjects error:error];
		};

		BOOL (^serializeRelationship)(NSRelationshipDescription *) = ^(NSRelationshipDescription *relationshipDescription) {
			if (value == nil) return YES;

			if ([relationshipDescription isToMany]) {
				if (![value conformsToProtocol:@protocol(NSFastEnumeration)]) {
					if (error != NULL) {
						NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property of class %@ cannot be encoded into a to-many relationship.", @""), [value class]];

						NSDictionary *userInfo = @{
							NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
							NSLocalizedFailureReasonErrorKey: failureReason,
						};

						*error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorUnsupportedRelationshipClass userInfo:userInfo];
					}

					return NO;
				}

				id relationshipCollection;
				if ([relationshipDescription isOrdered]) {
					relationshipCollection = [managedObject mutableOrderedSetValueForKey:managedObjectKey];
				} else {
					relationshipCollection = [managedObject mutableSetValueForKey:managedObjectKey];
				}

				for (MTLModel *model in value) {
					NSManagedObject *nestedObject = objectForRelationshipFromModel(model);
					if (nestedObject == nil) return NO;

					[relationshipCollection addObject:nestedObject];
				}
			} else {
				NSManagedObject *nestedObject = objectForRelationshipFromModel(value);
				if (nestedObject == nil) return NO;

				[managedObject setValue:nestedObject forKey:managedObjectKey];
			}

			return YES;
		};

		BOOL (^serializeProperty)(NSPropertyDescription *) = ^(NSPropertyDescription *propertyDescription) {
			if (propertyDescription == nil) {
				if (error != NULL) {
					NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"No property by name \"%@\" exists on the entity.", @""), managedObjectKey];

					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
						NSLocalizedFailureReasonErrorKey: failureReason,
					};

					*error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorInvalidManagedObjectKey userInfo:userInfo];
				}

				return NO;
			}

			// Jump through some hoops to avoid referencing classes directly.
			NSString *propertyClassName = NSStringFromClass(propertyDescription.class);
			if ([propertyClassName isEqual:@"NSAttributeDescription"]) {
				return serializeAttribute((id)propertyDescription);
			} else if ([propertyClassName isEqual:@"NSRelationshipDescription"]) {
				return serializeRelationship((id)propertyDescription);
			} else {
				if (error != NULL) {
					NSString *failureReason = [NSString stringWithFormat:NSLocalizedString(@"Property descriptions of class %@ are unsupported.", @""), propertyClassName];

					NSDictionary *userInfo = @{
						NSLocalizedDescriptionKey: NSLocalizedString(@"Could not serialize managed object", @""),
						NSLocalizedFailureReasonErrorKey: failureReason,
					};

					*error = [NSError errorWithDomain:MTLManagedObjectAdapterErrorDomain code:MTLManagedObjectAdapterErrorUnsupportedManagedObjectPropertyType userInfo:userInfo];
				}

				return NO;
			}
		};
		
		if (!serializeProperty(managedObjectProperties[managedObjectKey])) {
			performInContext(context, ^ id {
				[context deleteObject:managedObject];
				return nil;
			});

			managedObject = nil;
			*stop = YES;
		}
	}];

	if (![managedObject validateForInsert:error]) {
		performInContext(context, ^ id {
			[context deleteObject:managedObject];
			return nil;
		});
	}

	return managedObject;
}

+ (NSManagedObject *)managedObjectFromModel:(MTLModel<MTLManagedObjectSerializing> *)model insertingIntoContext:(NSManagedObjectContext *)context error:(NSError **)error {
	CFDictionaryKeyCallBacks keyCallbacks = kCFTypeDictionaryKeyCallBacks;

	// Compare MTLModel keys using pointer equality, not -isEqual:.
	keyCallbacks.equal = NULL;

	CFMutableDictionaryRef processedObjects = CFDictionaryCreateMutable(NULL, 0, &keyCallbacks, &kCFTypeDictionaryValueCallBacks);
	if (processedObjects == NULL) return nil;

	@onExit {
		CFRelease(processedObjects);
	};

	return [self managedObjectFromModel:model insertingIntoContext:context processedObjects:processedObjects error:error];
}

+ (NSManagedObject *)managedObjectFromModel:(MTLModel<MTLManagedObjectSerializing> *)model insertingIntoContext:(NSManagedObjectContext *)context processedObjects:(CFMutableDictionaryRef)processedObjects error:(NSError **)error {
	NSParameterAssert(model != nil);
	NSParameterAssert(context != nil);
	NSParameterAssert(processedObjects != nil);

	const void *existingManagedObject = CFDictionaryGetValue(processedObjects, (__bridge void *)model);
	if (existingManagedObject != NULL) {
		return (__bridge id)existingManagedObject;
	}

	MTLManagedObjectAdapter *adapter = [[self alloc] initWithModelClass:model.class];
	return [adapter managedObjectFromModel:model insertingIntoContext:context processedObjects:processedObjects error:error];
}

- (NSValueTransformer *)entityAttributeTransformerForKey:(NSString *)key {
	NSParameterAssert(key != nil);

	SEL selector = MTLSelectorWithKeyPattern(key, "EntityAttributeTransformer");
	if ([self.modelClass respondsToSelector:selector]) {
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[self.modelClass methodSignatureForSelector:selector]];
		invocation.target = self.modelClass;
		invocation.selector = selector;
		[invocation invoke];

		__unsafe_unretained id result = nil;
		[invocation getReturnValue:&result];
		return result;
	}

	if ([self.modelClass respondsToSelector:@selector(entityAttributeTransformerForKey:)]) {
		return [self.modelClass entityAttributeTransformerForKey:key];
	}

	return nil;
}

- (NSValueTransformer *)relationshipModelTransformerForKey:(NSString *)key {
    NSParameterAssert(key != nil);
    
    SEL selector = MTLSelectorWithKeyPattern(key, "RelationshipModelTransformer");
    if ([self.modelClass respondsToSelector:selector]) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[self.modelClass methodSignatureForSelector:selector]];
        invocation.target = self.modelClass;
        invocation.selector = selector;
        [invocation invoke];
        
        __unsafe_unretained id result = nil;
        [invocation getReturnValue:&result];
        return result;
    }
    
    
	if ([self.modelClass respondsToSelector:@selector(relationshipModelTransformerForKey:)]) {
		return [self.modelClass relationshipModelTransformerForKey:key];
	}
    
	return nil;
}

- (NSString *)managedObjectKeyForKey:(NSString *)key {
	NSParameterAssert(key != nil);

	id managedObjectKey = self.managedObjectKeysByPropertyKey[key];
	if ([managedObjectKey isEqual:NSNull.null]) return nil;

	if (managedObjectKey == nil) {
		return key;
	} else {
		return managedObjectKey;
	}
}

@end
