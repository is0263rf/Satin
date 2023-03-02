//
//  Renderer.swift
//  Satin
//
//  Created by Reza Ali on 7/23/19.
//  Copyright © 2019 Reza Ali. All rights reserved.
//

import Combine
import Metal
import simd

open class Renderer {
    public var label = "Satin Renderer"

    public var onUpdate: (() -> Void)?
    public var preDraw: ((_ renderEncoder: MTLRenderCommandEncoder) -> Void)?
    public var postDraw: ((_ renderEncoder: MTLRenderCommandEncoder) -> Void)?

    public var sortObjects = false

    public var context: Context {
        didSet {
            if oldValue != context {
                updateColorTexture = true
                updateDepthTexture = true
                updateStencilTexture = true
            }
        }
    }

    public var size: (width: Float, height: Float) = (0, 0) {
        didSet {
            if oldValue.width != size.width || oldValue.height != size.height {
                let width = Double(size.width)
                let height = Double(size.height)
                viewport = MTLViewport(
                    originX: 0.0,
                    originY: 0.0,
                    width: width,
                    height: height,
                    znear: invertViewportNearFar ? 1.0 : 0.0,
                    zfar: invertViewportNearFar ? 0.0 : 1.0
                )
                updateColorTexture = true
                updateDepthTexture = true
                updateStencilTexture = true
            }
        }
    }

    public var clearColor: MTLClearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
    public var clearDepth = 0.0
    public var clearStencil: UInt32 = 0

    public var updateColorTexture = true
    public var colorTexture: MTLTexture?

    public var colorLoadAction: MTLLoadAction = .clear
    public var colorStoreAction: MTLStoreAction = .store

    public var updateDepthTexture = true
    public var depthTexture: MTLTexture?

    public var depthLoadAction: MTLLoadAction = .clear
    public var depthStoreAction: MTLStoreAction = .dontCare

    public var updateStencilTexture = true
    public var stencilTexture: MTLTexture?

    public var stencilLoadAction: MTLLoadAction = .clear
    public var stencilStoreAction: MTLStoreAction = .dontCare

    public var viewport = MTLViewport() {
        didSet {
            _viewport = simd_make_float4(
                Float(viewport.originX),
                Float(viewport.originY),
                Float(viewport.width),
                Float(viewport.height)
            )
        }
    }

    public var invertViewportNearFar = false {
        didSet {
            let width = Double(size.width)
            let height = Double(size.height)
            viewport = MTLViewport(
                originX: 0.0,
                originY: 0.0,
                width: width,
                height: height,
                znear: invertViewportNearFar ? 1.0 : 0.0,
                zfar: invertViewportNearFar ? 0.0 : 1.0
            )
        }
    }

    private var _viewport: simd_float4 = .zero

    private var renderList: [Renderable] = []
    private var lightList: [Light] = []

    private var _updateLightBuffer = false
    private var lightBuffer: StructBuffer<LightData>?
    private var lightSubscriptions = Set<AnyCancellable>()

    // MARK: - Init

    public init(context: Context) {
        self.context = context
    }

    public func setClearColor(_ color: simd_float4) {
        clearColor = .init(red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: Double(color.w))
    }

    // MARK: - Drawing

    public func draw(renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, scene: Object, camera: Camera, renderTarget: MTLTexture)
    {
        if context.sampleCount > 1 {
            let resolveTexture = renderPassDescriptor.colorAttachments[0].resolveTexture
            renderPassDescriptor.colorAttachments[0].resolveTexture = renderTarget
            draw(renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer, scene: scene, camera: camera)
            renderPassDescriptor.colorAttachments[0].resolveTexture = resolveTexture
        } else {
            let renderTexture = renderPassDescriptor.colorAttachments[0].texture
            renderPassDescriptor.colorAttachments[0].texture = renderTarget
            draw(renderPassDescriptor: renderPassDescriptor, commandBuffer: commandBuffer, scene: scene, camera: camera)
            renderPassDescriptor.colorAttachments[0].texture = renderTexture
        }
    }

    public func draw(renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, scene: Object, camera: Camera)
    {
        update(scene: scene, camera: camera)

        let inColorTexture = renderPassDescriptor.colorAttachments[0].texture
        let inColorResolveTexture = renderPassDescriptor.colorAttachments[0].resolveTexture
        let inDepthTexture = renderPassDescriptor.depthAttachment.texture
        let inStencilTexture = renderPassDescriptor.stencilAttachment.texture

        let sampleCount = context.sampleCount
        let colorPixelFormat = context.colorPixelFormat
        let depthPixelFormat = context.depthPixelFormat
        let stencilPixelFormat = context.stencilPixelFormat

        // Set Color Texture

        if sampleCount > 1, inColorTexture?.sampleCount != sampleCount || inColorTexture?.pixelFormat != colorPixelFormat
        {
            setupColorTexture()
            renderPassDescriptor.colorAttachments[0].texture = colorTexture
        }

        // Set Depth Texture

        if inDepthTexture?.sampleCount != sampleCount || inDepthTexture?.pixelFormat != depthPixelFormat
        {
            setupDepthTexture()
            renderPassDescriptor.depthAttachment.texture = depthTexture
            if depthPixelFormat == .depth32Float_stencil8 {
                renderPassDescriptor.stencilAttachment.texture = depthTexture
            }
        }

        // Set Stencil Texture

        if inStencilTexture?.sampleCount != sampleCount || inStencilTexture?.pixelFormat != stencilPixelFormat
        {
            setupStencilTexture()
            if depthPixelFormat == .depth32Float_stencil8 {
                renderPassDescriptor.stencilAttachment.texture = depthTexture
            } else {
                renderPassDescriptor.stencilAttachment.texture = stencilTexture
            }
        }

        if sampleCount > 1 {
            if colorStoreAction == .store || colorStoreAction == .storeAndMultisampleResolve {
                renderPassDescriptor.colorAttachments[0].storeAction = .storeAndMultisampleResolve
            } else {
                renderPassDescriptor.colorAttachments[0].storeAction = .multisampleResolve
            }
        } else {
            if colorStoreAction == .store || colorStoreAction == .storeAndMultisampleResolve {
                renderPassDescriptor.colorAttachments[0].storeAction = .store
            } else {
                renderPassDescriptor.colorAttachments[0].storeAction = .dontCare
            }
        }

        renderPassDescriptor.colorAttachments[0].clearColor = clearColor
        renderPassDescriptor.colorAttachments[0].loadAction = colorLoadAction

        renderPassDescriptor.depthAttachment.loadAction = depthLoadAction
        renderPassDescriptor.depthAttachment.storeAction = depthStoreAction
        renderPassDescriptor.depthAttachment.clearDepth = clearDepth

        renderPassDescriptor.stencilAttachment.loadAction = stencilLoadAction
        renderPassDescriptor.stencilAttachment.storeAction = stencilStoreAction
        renderPassDescriptor.stencilAttachment.clearStencil = clearStencil

        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        {
            renderEncoder.label = label + " Encoder"
            renderEncoder.setViewport(viewport)
            encode(renderEncoder: renderEncoder, scene: scene)
            renderEncoder.endEncoding()
        }

        renderPassDescriptor.colorAttachments[0].texture = inColorTexture
        renderPassDescriptor.colorAttachments[0].resolveTexture = inColorResolveTexture
        renderPassDescriptor.depthAttachment.texture = inDepthTexture
        renderPassDescriptor.stencilAttachment.texture = inStencilTexture
    }

    public func draw(renderEncoder: MTLRenderCommandEncoder, scene: Object, camera: Camera) {
        update(scene: scene, camera: camera)
        encode(renderEncoder: renderEncoder, scene: scene)
    }

    // MARK: - Internal Update

    func update(scene: Object, camera: Camera) {
        onUpdate?()

        renderList = []
        lightList = []

        camera.update() // FIXME: - traverse children and make sure you update everything

        updateScene(object: scene, camera: camera)
        updateLights(lights: lightList)
    }

    func updateScene(object: Object, camera: Camera, visible: Bool = true) {
        object.context = context
        object.update()
        object.update(camera: camera, viewport: _viewport)

        if visible && object.visible {
            if let light = object as? Light {
                lightList.append(light)
            } else if let renderable = object as? Renderable, renderable.drawable {
                renderList.append(renderable)
            }
        }

        for child in object.children {
            updateScene(object: child, camera: camera, visible: visible && object.visible)
        }
    }

    // MARK: - Internal Encoding

    func encode(renderEncoder: MTLRenderCommandEncoder, scene: Object) {
        guard scene.visible, !renderList.isEmpty else { return }

        renderEncoder.pushDebugGroup(label + " Pass")
        preDraw?(renderEncoder)

        var renderables = renderList
        if sortObjects {
            renderables.sort {
                $0.renderOrder < $1.renderOrder
            }
        }

        for renderable in renderables {
            _encode(renderEncoder: renderEncoder, renderable: renderable)
        }

        postDraw?(renderEncoder)
        renderEncoder.popDebugGroup()
    }

    func _encode(renderEncoder: MTLRenderCommandEncoder, renderable: Renderable) {
        renderEncoder.pushDebugGroup(renderable.label)

        if let material = renderable.material, material.lighting {
            if let lightBuffer = lightBuffer {
                material.maxLights = lightBuffer.count
                renderEncoder.setFragmentBuffer(lightBuffer.buffer, offset: lightBuffer.offset, index: FragmentBufferIndex.Lighting.rawValue)
            } else {
                material.maxLights = 0
            }
            material.update()
        }

        renderable.draw(renderEncoder: renderEncoder, shadow: false)

        renderEncoder.popDebugGroup()
    }

    // MARK: - Resizing

    public func resize(_ size: (width: Float, height: Float)) {
        self.size = size
    }

    // MARK: - Textures

    func setupDepthTexture() {
        guard updateDepthTexture else { return }

        let sampleCount = context.sampleCount
        let depthPixelFormat = context.depthPixelFormat
        if depthPixelFormat != .invalid, size.width > 1, size.height > 1 {
            let descriptor = MTLTextureDescriptor()
            descriptor.pixelFormat = depthPixelFormat
            descriptor.width = Int(size.width)
            descriptor.height = Int(size.height)
            descriptor.sampleCount = sampleCount
            descriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            descriptor.resourceOptions = .storageModePrivate
            depthTexture = context.device.makeTexture(descriptor: descriptor)
            depthTexture?.label = label + " Depth Texture"
            updateDepthTexture = false
        } else {
            depthTexture = nil
        }
    }

    func setupStencilTexture() {
        guard updateStencilTexture else { return }

        let sampleCount = context.sampleCount
        let stencilPixelFormat = context.stencilPixelFormat
        if stencilPixelFormat != .invalid, size.width > 1, size.height > 1 {
            let descriptor = MTLTextureDescriptor()
            descriptor.pixelFormat = stencilPixelFormat
            descriptor.width = Int(size.width)
            descriptor.height = Int(size.height)
            descriptor.sampleCount = sampleCount
            descriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            descriptor.resourceOptions = .storageModePrivate
            stencilTexture = context.device.makeTexture(descriptor: descriptor)
            stencilTexture?.label = label + " Stencil Texture"
            updateStencilTexture = false
        } else {
            stencilTexture = nil
        }
    }

    func setupColorTexture() {
        guard updateColorTexture else { return }

        let sampleCount = context.sampleCount
        let colorPixelFormat = context.colorPixelFormat
        if colorPixelFormat != .invalid, size.width > 1, size.height > 1, sampleCount > 1 {
            let descriptor = MTLTextureDescriptor()
            descriptor.pixelFormat = colorPixelFormat
            descriptor.width = Int(size.width)
            descriptor.height = Int(size.height)
            descriptor.sampleCount = sampleCount
            descriptor.textureType = .type2DMultisample
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            descriptor.resourceOptions = .storageModePrivate
            colorTexture = context.device.makeTexture(descriptor: descriptor)
            colorTexture?.label = label + " Color Texture"
            updateColorTexture = false
        } else {
            colorTexture = nil
        }
    }

    // MARK: - Scene Graph

    // MARK: - Lights

    func updateLights(lights: [Light]) {
        setupLightBuffer(lights: lights)
        updateLightBuffer(lights: lights)
    }

    func setupLightBuffer(lights: [Light]) {
        guard !lights.isEmpty, lights.count != lightBuffer?.count else { return }

        lightSubscriptions.removeAll()

        if lights.isEmpty {
            lightBuffer = nil
        } else {
            for light in lights {
                light.publisher.sink { [weak self] _ in
                    self?._updateLightBuffer = true
                }.store(in: &lightSubscriptions)
            }

            lightBuffer = StructBuffer<LightData>.init(device: context.device, count: lights.count, label: "Light Buffer")
            _updateLightBuffer = true
        }
    }

    func updateLightBuffer(lights: [Light]) {
        guard let lightBuffer = lightBuffer, _updateLightBuffer else { return }
        lightBuffer.update(data: lights.map { $0.data })
        _updateLightBuffer = false
    }

    // MARK: - Compile

    public func compile(scene: Object, camera: Camera) {
        _compile(object: scene, camera: camera)
    }

    func _compile(object: Object, camera: Camera) {
        object.context = context
        for child in object.children {
            _compile(object: child, camera: camera)
        }
    }
}
