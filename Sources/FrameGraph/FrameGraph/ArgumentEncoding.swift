//
//  ArgumentEncoder.swift
//  RenderAPI
//
//  Created by Thomas Roughton on 22/02/18.
//

import Foundation
import FrameGraphUtilities
import CAtomics

public protocol FunctionArgumentKey {
    var stringValue : String { get }
    func bindingPath(arrayIndex: Int, argumentBufferPath: ResourceBindingPath?) -> ResourceBindingPath?
}

extension RawRepresentable where Self.RawValue == String {
    public var stringValue : String {
        return self.rawValue
    }
}

#if canImport(Metal)
import Metal

public struct MetalIndexedFunctionArgument : FunctionArgumentKey {
    public var type: MTLArgumentType
    public var index : Int
    public var stages : RenderStages
    
    @inlinable
    public init(type: MTLArgumentType, index: Int, stages: RenderStages) {
        self.type = type
        self.index = index
        self.stages = stages
    }
    
    @inlinable
    public var stringValue : String {
        return "\(type)_arg\(index)"
    }
    
    @inlinable
    public func bindingPath(arrayIndex: Int, argumentBufferPath: ResourceBindingPath?) -> ResourceBindingPath? {
        return ResourceBindingPath(stages: MTLRenderStages(self.stages), type: self.type, argumentBufferIndex: nil, index: self.index + arrayIndex)
    }
}
#endif


public struct FunctionArgumentCodingKey : FunctionArgumentKey {
    public let codingKey : CodingKey
    
    @inlinable
    public init(_ codingKey: CodingKey) {
        self.codingKey = codingKey
    }
    
    @inlinable
    public var stringValue: String {
        return self.codingKey.stringValue
    }
}

extension FunctionArgumentKey {
    
    @inlinable
    public func bindingPath(arrayIndex: Int, argumentBufferPath: ResourceBindingPath?) -> ResourceBindingPath? {
        return nil
    }
    
    @inlinable
    func bindingPath(argumentBufferPath: ResourceBindingPath?, arrayIndex: Int, pipelineReflection: PipelineReflection) -> ResourceBindingPath? {
        return self.bindingPath(arrayIndex: arrayIndex, argumentBufferPath: argumentBufferPath) ?? pipelineReflection.bindingPath(argumentName: self.stringValue, arrayIndex: arrayIndex, argumentBufferPath: argumentBufferPath)
    }
    
    @inlinable
    func computedBindingPath(pipelineReflection: PipelineReflection) -> ResourceBindingPath? {
        return self.bindingPath(arrayIndex: 0, argumentBufferPath: nil) ?? pipelineReflection.bindingPath(argumentName: self.stringValue, arrayIndex: 0, argumentBufferPath: nil)
    }
}

extension String : FunctionArgumentKey {
    @inlinable
    public var stringValue : String {
        return self
    }
}

public protocol ArgumentBufferEncodable {
    static var activeStages : RenderStages { get }
    
    func encode(into argBuffer: _ArgumentBuffer, setIndex: Int, bindingEncoder: ResourceBindingEncoder?)
}

public struct _ArgumentBuffer : ResourceProtocol {
    
    @usableFromInline let _handle : UnsafeRawPointer
    @inlinable public var handle : Handle { return UInt64(UInt(bitPattern: _handle)) }
    
    public enum ArgumentResource {
        case buffer(Buffer, offset: Int)
        case texture(Texture)
        case sampler(SamplerDescriptor)
        // Where offset is the source offset in the source Data.
        case bytes(offset: Int, length: Int)
    }
    
    public init(handle: Handle) {
        assert(Resource(handle: handle).type == .argumentBuffer)
        self._handle = UnsafeRawPointer(bitPattern: UInt(handle))!
    }
    
    @inlinable
    init(frameGraph: FrameGraph? = nil, flags: ResourceFlags = []) {
        precondition(!flags.contains(.historyBuffer), "Argument Buffers cannot be used as history buffers.")
        
        let index : UInt64
        if flags.contains(.persistent) {
            index = PersistentArgumentBufferRegistry.instance.allocate(flags: flags)
        } else {
            guard let frameGraph = frameGraph ?? FrameGraph.activeFrameGraph else {
                fatalError("The FrameGraph must be specified for transient resources created outside of a render pass' execute() method.")
            }
            
            index = TransientArgumentBufferRegistry.instances[frameGraph.transientRegistryIndex].allocate(flags: flags)
        }
        
        let handle = index | (UInt64(flags.rawValue) << Self.flagBitsRange.lowerBound) | (UInt64(ResourceType.argumentBuffer.rawValue) << Self.typeBitsRange.lowerBound)
        self._handle = UnsafeRawPointer(bitPattern: UInt(handle))!
        assert(self.encoder == nil)
    }
    
    @inlinable
    init(flags: ResourceFlags = [], sourceArray: _ArgumentBufferArray) {
        let index : UInt64
        if flags.contains(.persistent) {
            index = PersistentArgumentBufferRegistry.instance.allocate(flags: flags, sourceArray: sourceArray)
        } else {
            index = TransientArgumentBufferRegistry.instances[sourceArray.transientRegistryIndex].allocate(flags: flags, sourceArray: sourceArray)
        }
        
        let handle = index | (UInt64(flags.rawValue) << Self.flagBitsRange.lowerBound) | (UInt64(ResourceType.argumentBuffer.rawValue) << Self.typeBitsRange.lowerBound)
        self._handle = UnsafeRawPointer(bitPattern: UInt(handle))!
        assert(self.encoder == nil)
    }
    
    @inlinable
    public var sourceArray : _ArgumentBufferArray? {
        if self.flags.contains(.resourceView) {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                return PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].sourceArrays[indexInChunk]
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                return TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].sourceArrays[indexInChunk]
            }
        }
        return nil
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            return []
        }
        nonmutating set {
        }
    }
    
    @inlinable
    public var usages : ResourceUsagesList {
        get {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                return PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].usages[indexInChunk]
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                return TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].usages[indexInChunk]
            }
        }
    }
    
    @inlinable
    public var encoder : UnsafeRawPointer? {
        get {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                return CAtomicsLoad(PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].encoders.advanced(by: indexInChunk), .relaxed)
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                return CAtomicsLoad(TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].encoders.advanced(by: indexInChunk), .relaxed)
            }
        }
        nonmutating set {
            if let newValue = newValue {
                if self._usesPersistentRegistry {
                    let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                    return CAtomicsStore(PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].encoders.advanced(by: indexInChunk), newValue, .relaxed)
                } else {
                    let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                    return CAtomicsStore(TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].encoders.advanced(by: indexInChunk), newValue, .relaxed)
                }
            }
        }
    }
    
    @inlinable
    var usagesPointer: UnsafeMutablePointer<ResourceUsagesList> {
        get {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                return PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].usages.advanced(by: indexInChunk)
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                return TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].usages.advanced(by: indexInChunk)
            }
        }
    }
    
    @inlinable
    public var enqueuedBindings : ExpandingBuffer<(FunctionArgumentKey, Int, _ArgumentBuffer.ArgumentResource)> {
        _read {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                yield PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].enqueuedBindings[indexInChunk]
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                yield TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].enqueuedBindings[indexInChunk]
            }
        }
        nonmutating _modify {
            self.waitForCPUAccess(accessType: .write)
            
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                yield &PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].enqueuedBindings[indexInChunk]
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                yield &TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].enqueuedBindings[indexInChunk]
            }
            
            self.stateFlags.remove(.initialised)
        }
    }
    
    @inlinable
    public var bindings : ExpandingBuffer<(ResourceBindingPath, _ArgumentBuffer.ArgumentResource)> {
        _read {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                yield PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].bindings[indexInChunk]
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                yield TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].bindings[indexInChunk]
            }
        }
        nonmutating _modify {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                yield &PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].bindings[indexInChunk]
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                yield &TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].bindings[indexInChunk]
            }
        }
    }
    
    @inlinable
    public var label : String? {
        get {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                return PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].labels[indexInChunk]
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                return TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].labels[indexInChunk]
            }
        }
        nonmutating set {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].labels[indexInChunk] = newValue
            } else {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: TransientArgumentBufferRegistry.Chunk.itemsPerChunk)
                TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].chunks[chunkIndex].labels[indexInChunk] = newValue
            }
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return .shared
    }
    
    // Thread-safe
    public func translateEnqueuedBindings(_ closure: (FunctionArgumentKey, Int, _ArgumentBuffer.ArgumentResource) -> ResourceBindingPath?) {
        
        func translateBindings() {
            var i = 0
            while i < self.enqueuedBindings.count {
                let (key, arrayIndex, binding) = self.enqueuedBindings[i]
                if let bindingPath = closure(key, arrayIndex, binding) {
                    self.enqueuedBindings.remove(at: i)
                    self.bindings.append((bindingPath, binding))
                } else {
                    i += 1
                }
            }
        }

        if self._usesPersistentRegistry {
            PersistentArgumentBufferRegistry.instance.lock.withLock {
                translateBindings()
            }
        } else {
            TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].lock.withLock {
                translateBindings()
            }
        }
    }
    
    @inlinable
    public func _bytes(offset: Int) -> UnsafeRawPointer {
        if self._usesPersistentRegistry {
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
            return PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].inlineDataStorage[indexInChunk].withUnsafeBytes { return $0.baseAddress! + offset }
        } else {
            return UnsafeRawPointer(TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].inlineDataAllocator.buffer!) + offset
        }
    }
    
    /// returns the offset in bytes into the buffer's storage
    @inlinable
    public func _copyBytes(_ bytes: UnsafeRawPointer, length: Int) -> Int {
        if self._usesPersistentRegistry {
            return PersistentArgumentBufferRegistry.instance.lock.withLock {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
                let offset = PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].inlineDataStorage[indexInChunk].count
                PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].inlineDataStorage[indexInChunk].append(bytes.assumingMemoryBound(to: UInt8.self), count: length)
                return offset
            }
        } else {
            return TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].lock.withLock {
                let offset = TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].inlineDataAllocator.count
                TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].inlineDataAllocator.append(from: bytes.assumingMemoryBound(to: UInt8.self), count: length)
                return offset
            }
        }
    }
    
    public subscript(waitIndexFor queue: Queue, accessType type: ResourceAccessType) -> UInt64 {
        get {
            guard self._usesPersistentRegistry else { return 0 }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
            if type == .read {
                return PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].readWaitIndices[indexInChunk][Int(queue.index)]
            } else {
                return PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].writeWaitIndices[indexInChunk][Int(queue.index)]
            }
        }
        nonmutating set {
            guard self._usesPersistentRegistry else { return }
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
            
            if type == .read || type == .readWrite {
                PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].readWaitIndices[indexInChunk][Int(queue.index)] = newValue
            }
            if type == .write || type == .readWrite {
                PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].writeWaitIndices[indexInChunk][Int(queue.index)] = newValue
            }
        }
    }
    
    public func dispose() {
        guard self._usesPersistentRegistry else {
            return
        }
        PersistentArgumentBufferRegistry.instance.dispose(self)
    }
    
    @inlinable
    public var isValid : Bool {
        if self._usesPersistentRegistry {
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferRegistry.Chunk.itemsPerChunk)
            return PersistentArgumentBufferRegistry.instance.chunks[chunkIndex].generations[indexInChunk] == self.generation
        } else {
            return TransientArgumentBufferRegistry.instances[self.transientRegistryIndex].generation == self.generation
        }
    }
}

public struct _ArgumentBufferArray : ResourceProtocol {
    @usableFromInline let _handle : UnsafeRawPointer
    @inlinable public var handle : Handle { return UInt64(UInt(bitPattern: _handle)) }
    
    @inlinable
    public init(handle: Handle) {
        assert(Resource(handle: handle).type == .argumentBufferArray)
        self._handle = UnsafeRawPointer(bitPattern: UInt(handle))!
    }
    
    init(frameGraph: FrameGraph? = nil, flags: ResourceFlags = []) {
        precondition(!flags.contains(.historyBuffer), "Argument Buffers cannot be used as history buffers.")
        
        let index : UInt64
        if flags.contains(.persistent) {
            index = PersistentArgumentBufferArrayRegistry.instance.allocate(flags: flags)
        } else {
            guard let frameGraph = frameGraph ?? FrameGraph.activeFrameGraph else {
                fatalError("The FrameGraph must be specified for transient resources created outside of a render pass' execute() method.")
            }
            index = TransientArgumentBufferArrayRegistry.instances[frameGraph.transientRegistryIndex].allocate(flags: flags)
        }
        
        let handle = index | (UInt64(flags.rawValue) << Self.flagBitsRange.lowerBound) | (UInt64(ResourceType.argumentBufferArray.rawValue) << Self.typeBitsRange.lowerBound)
        self._handle = UnsafeRawPointer(bitPattern: UInt(handle))!
    }
    
    public func dispose() {
        guard self._usesPersistentRegistry else {
            return
        }
        for binding in self._bindings {
            binding?.dispose()
        }
        PersistentArgumentBufferArrayRegistry.instance.dispose(self)
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            return []
        }
        nonmutating set {
        }
    }
    
    @inlinable
    public var _bindings : [_ArgumentBuffer?] {
        _read {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferArrayRegistry.Chunk.itemsPerChunk)
                yield PersistentArgumentBufferArrayRegistry.instance.chunks[chunkIndex].bindings[indexInChunk]
            } else {
                yield TransientArgumentBufferArrayRegistry.instances[self.transientRegistryIndex].bindings[self.index]
            }
        }
        nonmutating _modify {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferArrayRegistry.Chunk.itemsPerChunk)
                yield &PersistentArgumentBufferArrayRegistry.instance.chunks[chunkIndex].bindings[indexInChunk]
            } else {
                yield &TransientArgumentBufferArrayRegistry.instances[self.transientRegistryIndex].bindings[self.index]
            }
        }
    }
    
    @inlinable
    public var label : String? {
        get {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferArrayRegistry.Chunk.itemsPerChunk)
                return PersistentArgumentBufferArrayRegistry.instance.chunks[chunkIndex].labels[indexInChunk]
            } else {
                return TransientArgumentBufferArrayRegistry.instances[self.transientRegistryIndex].labels[self.index]
            }
        }
        nonmutating set {
            if self._usesPersistentRegistry {
                let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferArrayRegistry.Chunk.itemsPerChunk)
                PersistentArgumentBufferArrayRegistry.instance.chunks[chunkIndex].labels[indexInChunk] = newValue
            } else {
                TransientArgumentBufferArrayRegistry.instances[self.transientRegistryIndex].labels[self.index] = newValue
            }
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return .shared
    }
    
    public subscript(waitIndexFor queue: Queue, accessType type: ResourceAccessType) -> UInt64 {
        get {
            return 0
        }
        nonmutating set {
            // Argument buffer array waits are handled at _ArgumentBuffer granularity
           _ = newValue
        }
    }
    
    @inlinable
    public var isValid : Bool {
        if self._usesPersistentRegistry {
            let (chunkIndex, indexInChunk) = self.index.quotientAndRemainder(dividingBy: PersistentArgumentBufferArrayRegistry.Chunk.itemsPerChunk)
            return PersistentArgumentBufferArrayRegistry.instance.chunks[chunkIndex].generations[indexInChunk] == self.generation
        } else {
            return TransientArgumentBufferArrayRegistry.instances[self.transientRegistryIndex].generation == self.generation
        }
    }
}

public struct ArgumentBuffer<K : FunctionArgumentKey> : ResourceProtocol {
    
    public let argumentBuffer : _ArgumentBuffer
    
    @inlinable
    public init(handle: Handle) {
        self.argumentBuffer = _ArgumentBuffer(handle: handle)
    }
    
    @inlinable
    public init(frameGraph: FrameGraph? = nil, flags: ResourceFlags = []) {
        self.argumentBuffer = _ArgumentBuffer(frameGraph: frameGraph, flags: flags)
        self.argumentBuffer.label = "Argument Buffer \(K.self)"
    }
    
    public func dispose() {
        self.argumentBuffer.dispose()
    }
    
    @inlinable
    public var handle: Resource.Handle {
        return self.argumentBuffer.handle
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            return self.argumentBuffer.stateFlags
        }
        nonmutating set {
            self.argumentBuffer.stateFlags = newValue
        }
    }
    
    @inlinable
    public var flags : ResourceFlags {
        return self.argumentBuffer.flags
    }
    
    @inlinable
    public var sourceArray : ArgumentBufferArray<K>? {
        return self.argumentBuffer.sourceArray.map { ArgumentBufferArray(handle: $0.handle) }
    }
    
    @inlinable
    var usagesPointer: UnsafeMutablePointer<ResourceUsagesList> {
        return self.argumentBuffer.usagesPointer
    }
    
    @inlinable
    public var isValid: Bool {
        return self.argumentBuffer.isValid
    }
    
    
    @inlinable
    public var label : String? {
        get {
            return self.argumentBuffer.label
        }
        nonmutating set {
            self.argumentBuffer.label = newValue
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return self.argumentBuffer.storageMode
    }
    
    @inlinable
    public func setBuffer(_ buffer: Buffer?, offset: Int, key: K, arrayIndex: Int = 0) {
        guard let buffer = buffer else { return }
        
        assert(!self.flags.contains(.persistent) || buffer.flags.contains(.persistent), "A persistent argument buffer can only contain persistent resources.")
        self.argumentBuffer.enqueuedBindings.append(
            (key, arrayIndex, .buffer(buffer, offset: offset))
        )
    }
    
    @inlinable
    public func setTexture(_ texture: Texture, key: K, arrayIndex: Int = 0) {
        assert(!self.flags.contains(.persistent) || texture.flags.contains(.persistent), "A persistent argument buffer can only contain persistent resources.")
        self.argumentBuffer.enqueuedBindings.append(
            (key, arrayIndex, .texture(texture))
        )
    }
    
    @inlinable
    public func setSampler(_ sampler: SamplerDescriptor, key: K, arrayIndex: Int = 0) {
        self.argumentBuffer.enqueuedBindings.append(
            (key, arrayIndex, .sampler(sampler))
        )
    }

    @inlinable
    public func setValue<T : ResourceProtocol>(_ value: T, key: K, arrayIndex: Int = 0) {
        assertionFailure("Cannot set a resource with setValue; did you mean to use setTexture or setBuffer?")
    }
    
    @inlinable
    public func setValue<T>(_ value: T, key: K, arrayIndex: Int = 0) {
        assert(_isPOD(T.self), "Only POD types should be used with setValue.")
        
        var value = value
        withUnsafeBytes(of: &value) { bufferPointer in
            self.setBytes(bufferPointer.baseAddress!, length: bufferPointer.count, for: key, arrayIndex: arrayIndex)
        }
    }
    
    @inlinable
    public func setValue<T : ResourceProtocol>(_ value: T, key: FunctionArgumentKey, arrayIndex: Int = 0) {
        preconditionFailure("setValue should not be used with resources; use setBuffer or setTexture instead.")
    }
    
    @inlinable
    public func setBytes(_ bytes: UnsafeRawPointer, length: Int, for key: K, arrayIndex: Int = 0) {
        let currentOffset = self.argumentBuffer._copyBytes(bytes, length: length)
        self.argumentBuffer.enqueuedBindings.append(
            (key, arrayIndex, .bytes(offset: currentOffset, length: length))
        )
    }
    
}

extension ArgumentBuffer {
    
    public func setBuffers(_ buffers: [Buffer], offsets: [Int], keys: [K]) {
        for (buffer, (offset, key)) in zip(buffers, zip(offsets, keys)) {
            self.setBuffer(buffer, offset: offset, key: key)
        }
    }
    
    public func setTextures(_ textures: [Texture], keys: [K]) {
        for (texture, key) in zip(textures, keys) {
            self.setTexture(texture, key: key)
        }
    }
    
    public func setSamplers(_ samplers: [SamplerDescriptor], keys: [K]) {
        for (sampler, key) in zip(samplers, keys) {
            self.setSampler(sampler, key: key)
        }
    }
}

public struct ArgumentBufferArray<K : FunctionArgumentKey> : ResourceProtocol {
    public let argumentBufferArray : _ArgumentBufferArray
    
    @inlinable
    public init(handle: Handle) {
        self.argumentBufferArray = _ArgumentBufferArray(handle: handle)
    }
    
    public init(frameGraph: FrameGraph? = nil, flags: ResourceFlags = []) {
        self.argumentBufferArray = _ArgumentBufferArray(frameGraph: frameGraph, flags: flags)
        self.argumentBufferArray.label = "Argument Buffer Array \(K.self)"
    }
    
    public func dispose() {
        self.argumentBufferArray.dispose()
    }
    
    @inlinable
    public var handle: _ArgumentBufferArray.Handle {
        return self.argumentBufferArray.handle
    }
    
    @inlinable
    public var stateFlags: ResourceStateFlags {
        get {
            return self.argumentBufferArray.stateFlags
        }
        nonmutating set {
            self.argumentBufferArray.stateFlags = newValue
        }
    }
    
    @inlinable
    public var label : String? {
        get {
            return self.argumentBufferArray.label
        }
        nonmutating set {
            self.argumentBufferArray.label = newValue
        }
    }
    
    @inlinable
    public var storageMode: StorageMode {
        return self.argumentBufferArray.storageMode
    }
    
    @inlinable
    public var isValid: Bool {
        return self.argumentBufferArray.isValid
    }
    
    public func reserveCapacity(_ capacity: Int) {
        self.argumentBufferArray._bindings.reserveCapacity(capacity)
    }
    
    public subscript(index: Int) -> ArgumentBuffer<K> {
        get {
            if index >= self.argumentBufferArray._bindings.count {
                self.argumentBufferArray._bindings.append(contentsOf: repeatElement(nil, count: index - self.argumentBufferArray._bindings.count + 1))
            }
            
            if let buffer = self.argumentBufferArray._bindings[index] {
                return ArgumentBuffer(handle: buffer.handle)
            }
            
            let buffer = _ArgumentBuffer(flags: [self.flags, .resourceView], sourceArray: self.argumentBufferArray)
            self.argumentBufferArray._bindings[index] = buffer
            return ArgumentBuffer(handle: buffer.handle)
        }
    }
}
