#!/usr/bin/env swift
// Fits the icon artwork onto the macOS icon grid: an 824pt body centred on a 1024pt transparent canvas, with the
// soft drop shadow system icons carry. The artwork is a full-bleed rounded square, and macOS does not shrink or
// shadow icons itself, so without this it would look oversized next to every other Dock icon.
// Usage: make_icon.swift <artwork.png> <out.png>   (scripts/make_icon.sh turns that into Resources/AppIcon.icns)
import AppKit

guard CommandLine.arguments.count == 3, let art = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: make_icon.swift <artwork.png> <out.png>\n".utf8))
    exit(2)
}

let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsctx
nsctx.imageInterpolation = .high

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
nsctx.cgContext.setShadow(offset: CGSize(width: 0, height: -14), blur: 28,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
art.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
