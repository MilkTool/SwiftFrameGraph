//
//  FrameGraphContext.swift
//  
//
//  Created by Thomas Roughton on 21/06/20.
//

import FrameGraphUtilities
import Foundation
import Dispatch

final class FrameGraphContextImpl<Backend: SpecificRenderBackend>: _FrameGraphContext {
    public var accessSemaphore: DispatchSemaphore
       
    let backend: Backend
    let resourceRegistry: Backend.TransientResourceRegistry
    let commandGenerator: ResourceCommandGenerator<Backend>
    
    // var compactedResourceCommands = [CompactedResourceCommand<MetalCompactedResourceCommandType>]()
       
    var queueCommandBufferIndex: UInt64 = 0
    let syncEvent: Backend.Event
       
    let commandQueue: Backend.BackendQueue
       
    public let transientRegistryIndex: Int
    var frameGraphQueue: Queue
    
    var compactedResourceCommands = [CompactedResourceCommand<Backend.CompactedResourceCommandType>]()
       
    public init(backend: Backend, capabilities: QueueCapabilities, inflightFrameCount: Int, transientRegistryIndex: Int) {
        self.backend = backend
        self.frameGraphQueue = Queue(capabilities: capabilities)
        self.commandQueue = backend.makeQueue(frameGraphQueue: self.frameGraphQueue)
        self.transientRegistryIndex = transientRegistryIndex
        self.resourceRegistry = backend.makeTransientRegistry(index: transientRegistryIndex, inflightFrameCount: inflightFrameCount)
        self.accessSemaphore = DispatchSemaphore(value: inflightFrameCount)
        
        self.commandGenerator = ResourceCommandGenerator()
        self.syncEvent = backend.makeSyncEvent(for: self.frameGraphQueue)
    }
    
    deinit {
        backend.freeSyncEvent(for: self.frameGraphQueue)
        self.frameGraphQueue.dispose()
    }
    
    public func beginFrameResourceAccess() {
        self.backend.setActiveContext(self)
    }
    
    var resourceMap : FrameResourceMap<Backend> {
        return FrameResourceMap<Backend>(persistentRegistry: self.backend.resourceRegistry, transientRegistry: self.resourceRegistry)
    }
    
    static var resourceCommandArrayTag: TaggedHeap.Tag {
        return UInt64(bitPattern: Int64("FrameGraph Compacted Resource Commands".hashValue))
    }
    
    
    public func executeFrameGraph(passes: [RenderPassRecord], dependencyTable: DependencyTable<SwiftFrameGraph.DependencyType>, resourceUsages: ResourceUsages, completion: @escaping (Double) -> Void) {
        
        // Use separate command buffers for onscreen and offscreen work (Delivering Optimised Metal Apps and Games, WWDC 2019)
        self.resourceRegistry.prepareFrame()
        
        defer {
            TaggedHeap.free(tag: Self.resourceCommandArrayTag)
            
            self.resourceRegistry.cycleFrames()
            
            self.commandGenerator.reset()
            self.compactedResourceCommands.removeAll(keepingCapacity: true)
            
            self.backend.setActiveContext(nil)
        }
        
        if passes.isEmpty {
            completion(0.0)
            self.accessSemaphore.signal()
            return
        }
        
        var frameCommandInfo = FrameCommandInfo<Backend>(passes: passes, resourceUsages: resourceUsages, initialCommandBufferSignalValue: self.queueCommandBufferIndex + 1)
        self.commandGenerator.generateCommands(passes: passes, resourceUsages: resourceUsages, transientRegistry: self.resourceRegistry, frameCommandInfo: &frameCommandInfo)
        self.commandGenerator.executePreFrameCommands(queue: self.frameGraphQueue, resourceMap: self.resourceMap, frameCommandInfo: &frameCommandInfo)
        backend.compactResourceCommands(queue: self.frameGraphQueue, resourceMap: self.resourceMap, commandInfo: frameCommandInfo, commandGenerator: self.commandGenerator, into: &self.compactedResourceCommands)
        
        let lastCommandBufferIndex = frameCommandInfo.commandBufferCount - 1
        
        var commandBuffer : Backend.CommandBuffer? = nil
        
        var committedCommandBufferCount = 0
        
        var gpuStartTime: Double = 0.0
        
        let syncEvent = backend.syncEvent(for: self.frameGraphQueue)!
        
        func processCommandBuffer() {
            if let commandBuffer = commandBuffer {
                commandBuffer.presentSwapchains(resourceRegistry: resourceMap.transientRegistry)
                
                // Make sure that the sync event value is what we expect, so we don't update it past
                // the signal for another buffer before that buffer has completed.
                // We only need to do this if we haven't already waited in this command buffer for it.
                // if commandEncoderWaitEventValues[commandEncoderIndex] != self.queueCommandBufferIndex {
                //     commandBuffer.encodeWaitForEvent(self.syncEvent, value: self.queueCommandBufferIndex)
                // }
                // Then, signal our own completion.
                self.queueCommandBufferIndex += 1
                commandBuffer.signalEvent(syncEvent, value: self.queueCommandBufferIndex)
                
                let cbIndex = committedCommandBufferCount
                let queueCBIndex = self.queueCommandBufferIndex
                
                self.frameGraphQueue.lastSubmittedCommand = queueCBIndex
                
                commandBuffer.commit(onCompletion: { (commandBuffer) in
                    if let error = commandBuffer.error {
                        print("Error executing command buffer \(queueCBIndex): \(error)")
                    }
                    self.frameGraphQueue.lastCompletedCommand = queueCBIndex
                    if cbIndex == 0 {
                        gpuStartTime = commandBuffer.gpuStartTime
                    }
                    if cbIndex == lastCommandBufferIndex { // Only call completion for the last command buffer.
                        let gpuEndTime = commandBuffer.gpuEndTime
                        completion((gpuEndTime - gpuStartTime) * 1000.0)
                        self.accessSemaphore.signal()
                    }
                })
                committedCommandBufferCount += 1
                
            }
            commandBuffer = nil
        }
        
        var waitedEvents = QueueCommandIndices(repeating: 0)
        
        for (i, encoderInfo) in frameCommandInfo.commandEncoders.enumerated() {
            let commandBufferIndex = encoderInfo.commandBufferIndex
            if commandBufferIndex != committedCommandBufferCount {
                processCommandBuffer()
            }
            
            if commandBuffer == nil {
                commandBuffer = Backend.CommandBuffer(backend: self.backend,
                                                      queue: self.commandQueue,
                                                      commandInfo: frameCommandInfo,
                                                      textureUsages: self.commandGenerator.renderTargetTextureProperties,
                                                      resourceMap: resourceMap,
                                                      compactedResourceCommands: self.compactedResourceCommands)
            }
            
            let waitEventValues = encoderInfo.queueCommandWaitIndices
            for queue in QueueRegistry.allQueues {
                if waitedEvents[Int(queue.index)] < waitEventValues[Int(queue.index)],
                    waitEventValues[Int(queue.index)] > queue.lastCompletedCommand {
                    if let event = backend.syncEvent(for: queue) {
                        commandBuffer!.waitForEvent(event, value: waitEventValues[Int(queue.index)])
                    } else {
                        // It's not a queue known to this backend, so the best we can do is sleep and wait until the queue is completd.
                        while queue.lastCompletedCommand < waitEventValues[Int(queue.index)] {
                            sleep(0)
                        }
                    }
                }
            }
            waitedEvents = pointwiseMax(waitEventValues, waitedEvents)
            
            commandBuffer!.encodeCommands(encoderIndex: i)
        }
        
        processCommandBuffer()
    }
}
