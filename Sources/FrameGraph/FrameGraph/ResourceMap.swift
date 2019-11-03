//
//  ResourceMap.swift
//  MetalRenderer
//
//  Created by Thomas Roughton on 20/05/19.
//

import FrameGraphUtilities

public struct PersistentResourceMap<R : ResourceProtocol, V> {
    
    public let allocator : AllocatorType
    
    public typealias Index = Int
    
    @usableFromInline var keys : UnsafeMutablePointer<R>! = nil
    @usableFromInline var values : UnsafeMutablePointer<V>! = nil
    @usableFromInline var capacity = 0
    
    public init(allocator: AllocatorType = .system) {
        self.allocator = allocator
    }

    public mutating func prepareFrame() {
        switch R.self {
        case is Buffer.Type:
            self.reserveCapacity(PersistentBufferRegistry.instance.maxIndex)
        case is Texture.Type:
            self.reserveCapacity(PersistentTextureRegistry.instance.maxIndex)
        case is _ArgumentBuffer.Type:
            self.reserveCapacity(PersistentArgumentBufferRegistry.instance.maxIndex)
        case is _ArgumentBufferArray.Type:
            self.reserveCapacity(PersistentArgumentBufferArrayRegistry.instance.maxIndex)
        case is Heap.Type:
            self.reserveCapacity(HeapRegistry.instance.maxIndex)
        default:
            fatalError()
        }
    }
    
    @inlinable mutating func reserveCapacity(_ capacity: Int) {
        if capacity <= self.capacity {
            return
        }
        let capacity = max(capacity, 2 * self.capacity)
        
        let oldCapacity = self.capacity
        
        let newKeys : UnsafeMutablePointer<R> = Allocator.allocate(capacity: capacity, allocator: self.allocator)
        newKeys.initialize(repeating: R(handle: Resource.invalidResource.handle), count: capacity)
        
        let newValues : UnsafeMutablePointer<V> = Allocator.allocate(capacity: capacity, allocator: self.allocator)
        
        let oldKeys = self.keys
        let oldValues = self.values
        
        self.capacity = capacity
        self.keys = newKeys
        self.values = newValues
        
        for index in 0..<oldCapacity {
            if oldKeys.unsafelyUnwrapped[index].handle != Resource.invalidResource.handle {
                let sourceKey = oldKeys!.advanced(by: index).move()
                
                self.keys.advanced(by: index).initialize(to: sourceKey)
                self.values.advanced(by: index).moveInitialize(from: oldValues.unsafelyUnwrapped.advanced(by: index), count: 1)
            }
        }
        
        if oldCapacity > 0 {
            Allocator.deallocate(oldKeys!, allocator: self.allocator)
            Allocator.deallocate(oldValues!, allocator: self.allocator)
        }
    }
    
    
    public func `deinit`() {
        for bucket in 0..<self.capacity {
            if self.keys[bucket].handle != Resource.invalidResource.handle {
                self.values.advanced(by: bucket).deinitialize(count: 1)
            }
        }
        
        if self.capacity > 0 {
            Allocator.deallocate(self.keys, allocator: self.allocator)
            Allocator.deallocate(self.values, allocator: self.allocator)
        }
    }
    
    @inlinable
    public func contains(_ resource: R) -> Bool {
        if resource._usesPersistentRegistry {
            return self.keys[resource.index] == resource
        } else {
            return false
        }
    }
    
    @inlinable
    public subscript(resource: R) -> V? {
        _read {
            if resource._usesPersistentRegistry {
                assert(resource.index < self.capacity)
                
                if self.keys[resource.index] == resource {
                    yield self.values[resource.index]
                } else {
                    yield nil
                }
            } else {
                yield nil
            }
        }
        set {
            assert(resource._usesPersistentRegistry)
            assert(resource.index < self.capacity)
            if let newValue = newValue {
                if self.keys[resource.index] != R(handle: Resource.invalidResource.handle) {
                    self.values[resource.index] = newValue
                } else {
                    self.values.advanced(by: resource.index).initialize(to: newValue)
                }
                
                self.keys[resource.index] = resource
            } else {
                if self.keys[resource.index] != R(handle: Resource.invalidResource.handle) {
                    self.values.advanced(by: resource.index).deinitialize(count: 1)
                }
                
                self.keys[resource.index] = R(handle: Resource.invalidResource.handle)
            }
        }
    }
    
    @inlinable
    public subscript(resource: R, default default: @autoclosure () -> V) -> V {
        get {
            return self[resource] ?? `default`()
        }
        set {
            self[resource] = newValue
        }
    }
    
    @inlinable
    @discardableResult
    public mutating func removeValue(forKey resource: R) -> V? {
        if resource._usesPersistentRegistry {
            if self.keys[resource.index] != resource {
                return nil
            }
            
            self.keys[resource.index] = R(handle: Resource.invalidResource.handle)
            return self.values.advanced(by: resource.index).move()
        } else {
            return nil
        }
    }
    
    @inlinable
    public mutating func removeAll() {
        for bucket in 0..<self.capacity {
            if self.keys[bucket] != R(handle: Resource.invalidResource.handle) {
                self.keys[bucket] = R(handle: Resource.invalidResource.handle)
                self.values.advanced(by: bucket).deinitialize(count: 1)
            }
        }
    }
    
    @inlinable
    public mutating func removeAll(iterating iterator: (R, V, _ isPersistent: Bool) -> Void) {
        for bucket in 0..<self.capacity {
            if self.keys[bucket] != R(handle: Resource.invalidResource.handle) {
                iterator(self.keys[bucket], self.values[bucket], false)
                self.keys[bucket] = R(handle: Resource.invalidResource.handle)
                self.values.advanced(by: bucket).deinitialize(count: 1)
            }
        }
    }
    
    @inlinable
    public func forEach(_ body: ((R, V)) throws -> Void) rethrows {
        for bucket in 0..<self.capacity {
            if self.keys[bucket] != R(handle: Resource.invalidResource.handle) {
                try body((self.keys[bucket], self.values[bucket]))
            }
        }
    }
    
    @inlinable
    public mutating func forEachMutating(_ body: (R, inout V, _ deleteEntry: inout Bool) throws -> Void) rethrows {
        for bucket in 0..<self.capacity where self.keys[bucket] != R(handle: Resource.invalidResource.handle) {
            var deleteEntry = false
            try body(self.keys[bucket], &self.values[bucket], &deleteEntry)
            if deleteEntry {
                self.keys[bucket] = R(handle: Resource.invalidResource.handle)
                self.values.advanced(by: bucket).deinitialize(count: 1)
            }
        }
    }
    
    /// Passes back a pointer to the address where the value should go for a given key.
    /// The bool argument indicates whether the pointer is currently initialised.
    @inlinable
    public mutating func withValue<T>(forKey resource: R, perform: (UnsafeMutablePointer<V>, Bool) -> T) -> T {
        assert(resource._usesPersistentRegistry)
        return perform(self.values.advanced(by: resource.index), self.keys[resource.index] == resource)
    }
}


public struct TransientResourceMap<R : ResourceProtocol, V> {
    
    public let allocator : AllocatorType
    let transientRegistryIndex : Int
    
    public typealias Index = Int
    
    @usableFromInline var keys : UnsafeMutablePointer<R>! = nil
    
    @usableFromInline var values : UnsafeMutablePointer<V>! = nil
    
    @usableFromInline var capacity = 0
    
    public init(allocator: AllocatorType = .system, transientRegistryIndex: Int) {
        self.allocator = allocator
        self.transientRegistryIndex = transientRegistryIndex
    }

    public mutating func prepareFrame() {
        switch R.self {
        case is Buffer.Type:
            self.reserveCapacity(TransientBufferRegistry.instances[self.transientRegistryIndex].capacity)
        case is Texture.Type:
            self.reserveCapacity(TransientTextureRegistry.instances[self.transientRegistryIndex].capacity)
        case is _ArgumentBuffer.Type:
            self.reserveCapacity(TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].count)
        case is _ArgumentBufferArray.Type:
            self.reserveCapacity(TransientArgumentBufferArrayRegistry.instances[self.transientRegistryIndex].capacity)
        case is Heap.Type:
            break
        default:
            fatalError()
        }
    }
    
    @inlinable
    mutating func reserveCapacity(_ capacity: Int) {
        if capacity <= self.capacity {
            return
        }
        
        let oldCapacity = self.capacity
        
        let newKeys : UnsafeMutablePointer<R> = Allocator.allocate(capacity: capacity, allocator: self.allocator)
        newKeys.initialize(repeating: R(handle: Resource.invalidResource.handle), count: capacity)
        
        let newValues : UnsafeMutablePointer<V> = Allocator.allocate(capacity: capacity, allocator: self.allocator)
        
        let oldKeys = self.keys
        let oldValues = self.values
        
        self.capacity = capacity
        self.keys = newKeys
        self.values = newValues
        
        for index in 0..<oldCapacity {
            if oldKeys.unsafelyUnwrapped[index].handle != Resource.invalidResource.handle {
                let sourceKey = oldKeys!.advanced(by: index).move()
                
                self.keys.advanced(by: index).initialize(to: sourceKey)
                self.values.advanced(by: index).moveInitialize(from: oldValues.unsafelyUnwrapped.advanced(by: index), count: 1)
            }
        }
        
        if oldCapacity > 0 {
            Allocator.deallocate(oldKeys!, allocator: self.allocator)
            Allocator.deallocate(oldValues!, allocator: self.allocator)
        }
    }
    
    public func `deinit`() {
        for bucket in 0..<self.capacity {
            if self.keys[bucket].handle != Resource.invalidResource.handle {
                self.values.advanced(by: bucket).deinitialize(count: 1)
            }
        }
        if self.capacity > 0 {
            Allocator.deallocate(self.keys, allocator: self.allocator)
            Allocator.deallocate(self.values, allocator: self.allocator)
        }
    }
    
    @inlinable
    public func contains(_ resource: R) -> Bool {
        if resource._usesPersistentRegistry {
            return false
        } else {
            return self.keys[resource.index] == resource
        }
    }
    
    @inlinable
    public subscript(resource: R) -> V? {
        _read {
            if resource._usesPersistentRegistry {
                yield nil
            } else {
                assert(resource.index < self.capacity)
                
                if self.keys[resource.index] == resource {
                    yield self.values[resource.index]
                } else {
                    yield nil
                }
            }
        }
        set {
            assert(!resource._usesPersistentRegistry)
            assert(resource.index < self.capacity)
            
            if let newValue = newValue {
                if self.keys[resource.index] != R(handle: Resource.invalidResource.handle) {
                    self.values[resource.index] = newValue
                } else {
                    self.values.advanced(by: resource.index).initialize(to: newValue)
                }
                
                self.keys[resource.index] = resource
            } else {
                if self.keys[resource.index] != R(handle: Resource.invalidResource.handle) {
                    self.values.advanced(by: resource.index).deinitialize(count: 1)
                }
                
                self.keys[resource.index] = R(handle: Resource.invalidResource.handle)
            }
        }
    }
    
    @inlinable
    public subscript(resource: R, default default: @autoclosure () -> V) -> V {
        get {
            return self[resource] ?? `default`()
        }
        set {
            self[resource] = newValue
        }
    }
    
    @inlinable
    @discardableResult
    public mutating func removeValue(forKey resource: R) -> V? {
        if resource._usesPersistentRegistry {
            return nil
        } else {
            if self.keys[resource.index] != resource {
                return nil
            }
            
            self.keys[resource.index] = R(handle: Resource.invalidResource.handle)
            return self.values.advanced(by: resource.index).move()
        }
        
    }
    
    @inlinable
    public mutating func removeAll() {
        for bucket in 0..<self.capacity {
            if self.keys[bucket] != R(handle: Resource.invalidResource.handle) {
                self.keys[bucket] = R(handle: Resource.invalidResource.handle)
                self.values.advanced(by: bucket).deinitialize(count: 1)
            }
        }
    }
    
    @inlinable
    public mutating func removeAll(iterating iterator: (R, V, _ isPersistent: Bool) -> Void) {
        for bucket in 0..<self.capacity {
            if self.keys[bucket] != R(handle: Resource.invalidResource.handle) {
                iterator(self.keys[bucket], self.values[bucket], false)
                self.keys[bucket] = R(handle: Resource.invalidResource.handle)
                self.values.advanced(by: bucket).deinitialize(count: 1)
            }
        }
    }
    
    @inlinable
    public func forEach(_ body: ((R, V)) throws -> Void) rethrows {
        for bucket in 0..<self.capacity {
            if self.keys[bucket] != R(handle: Resource.invalidResource.handle) {
                try body((self.keys[bucket], self.values[bucket]))
            }
        }
    }
    
    @inlinable
    public mutating func forEachMutating(_ body: (R, inout V, _ deleteEntry: inout Bool) throws -> Void) rethrows {
        for bucket in 0..<self.capacity where self.keys[bucket] != R(handle: Resource.invalidResource.handle) {
            var deleteEntry = false
            try body(self.keys[bucket], &self.values[bucket], &deleteEntry)
            if deleteEntry {
                self.keys[bucket] = R(handle: Resource.invalidResource.handle)
                self.values.advanced(by: bucket).deinitialize(count: 1)
            }
        }
    }
    
    /// Passes back a pointer to the address where the value should go for a given key.
    /// The bool argument indicates whether the pointer is currently initialised.
    @inlinable
    public mutating func withValue<T>(forKey resource: R, perform: (UnsafeMutablePointer<V>, Bool) -> T) -> T {
        assert(!resource._usesPersistentRegistry)
        return perform(self.values.advanced(by: resource.index), self.keys[resource.index] == resource)
    }
}


/// A resource-specific constant-time access map specifically for FrameGraph resources.
public struct ResourceMap<R : ResourceProtocol, V> {
    
    public let allocator : AllocatorType
    
    public typealias Index = Int
    
    public var transientMap : TransientResourceMap<R, V>
    public var persistentMap : PersistentResourceMap<R, V>
    
    public init(allocator: AllocatorType = .system, transientRegistryIndex: Int) {
        self.allocator = allocator
        
        self.transientMap = TransientResourceMap(allocator: allocator, transientRegistryIndex: transientRegistryIndex)
        self.persistentMap = PersistentResourceMap(allocator: allocator)
    }

    public mutating func prepareFrame() {
        self.transientMap.prepareFrame()
        self.persistentMap.prepareFrame()
    }
    
    public func `deinit`() {
        self.transientMap.deinit()
        self.persistentMap.deinit()
    }
    
    @inlinable
    public func contains(_ resource: R) -> Bool {
        if resource._usesPersistentRegistry {
            return self.persistentMap.contains(resource)
        } else {
            return self.transientMap.contains(resource)
        }
    }
    
    @inlinable
    public subscript(resource: R) -> V? {
        _read {
            if resource._usesPersistentRegistry {
                yield self.persistentMap[resource]
            } else {
                yield self.transientMap[resource]
            }
        }
        set {
            if resource._usesPersistentRegistry {
                self.persistentMap[resource] = newValue
            } else {
                self.transientMap[resource] = newValue
            }
        }
    }
    
    @inlinable
    public subscript(resource: R, default default: @autoclosure () -> V) -> V {
        get {
            return self[resource] ?? `default`()
        }
        set {
            self[resource] = newValue
        }
    }
    
    @inlinable
    @discardableResult
    public mutating func removeValue(forKey resource: R) -> V? {
        if resource._usesPersistentRegistry {
            return self.persistentMap.removeValue(forKey: resource)
        } else {
            return self.transientMap.removeValue(forKey: resource)
        }
        
    }
    
    @inlinable
    public mutating func removeAll() {
        self.transientMap.removeAll()
        self.persistentMap.removeAll()
    }
    
    @inlinable
    public mutating func removeAll(iterating iterator: (R, V, _ isPersistent: Bool) -> Void) {
        self.transientMap.removeAll(iterating: iterator)
        self.persistentMap.removeAll(iterating: iterator)
    }
    
    @inlinable
    public func forEach(_ body: ((R, V)) throws -> Void) rethrows {
        try self.transientMap.forEach(body)
        try self.persistentMap.forEach(body)
    }
    
    @inlinable
    public mutating func forEachMutating(_ body: (R, inout V, _ deleteEntry: inout Bool) throws -> Void) rethrows {
        try self.transientMap.forEachMutating(body)
        try self.persistentMap.forEachMutating(body)
    }
    
    /// Passes back a pointer to the address where the value should go for a given key.
    /// The bool argument indicates whether the pointer is currently initialised.
    @inlinable
    public mutating func withValue<T>(forKey resource: R, perform: (UnsafeMutablePointer<V>, Bool) -> T) -> T {
        if resource._usesPersistentRegistry {
            return self.persistentMap.withValue(forKey: resource, perform: perform)
        } else {
            return self.transientMap.withValue(forKey: resource, perform: perform)
        }
    }
}