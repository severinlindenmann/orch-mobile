#!/usr/bin/env swift
// Generates the orch app icon (the orbit: a ring with one dot) into the AppIcon asset set.
// Usage: swift scripts/make-app-icon.swift [outputDir]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets/AppIcon.appiconset"

func rgb(_ hex: UInt32) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
          blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(background: CGColor?, ink: CGColor, name: String) {
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let info = CGImageAlphaInfo.premultipliedLast.rawValue
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: info)!
  let s = CGFloat(size)
  if let background {
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
  }
  let c = CGPoint(x: s / 2, y: s / 2)
  let radius: CGFloat = 270, stroke: CGFloat = 76, dotR: CGFloat = 84
  // 2 o'clock = 30 degrees above the horizontal axis (CG origin is bottom-left).
  let a = CGFloat.pi / 6
  let p = CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
  // Ring, with a clear gap around the dot so the dot reads as a separate body on the orbit.
  let gap = dotR + 30
  ctx.saveGState()
  ctx.addRect(CGRect(x: 0, y: 0, width: s, height: s))
  ctx.addEllipse(in: CGRect(x: p.x - gap, y: p.y - gap, width: gap * 2, height: gap * 2))
  ctx.clip(using: .evenOdd)
  ctx.setStrokeColor(ink)
  ctx.setLineWidth(stroke)
  ctx.strokeEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
  ctx.restoreGState()
  ctx.setFillColor(ink)
  ctx.fillEllipse(in: CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2))
  let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  guard CGImageDestinationFinalize(dest) else { fatalError("write failed: \(name)") }
  print("wrote \(url.path)")
}

let teal = rgb(0x2FC6A3)  // OrchUI Tokens.brand (dark)
render(background: rgb(0x0E1014), ink: teal, name: "AppIcon-any.png")
render(background: nil, ink: teal, name: "AppIcon-dark.png")
render(background: nil, ink: rgb(0xFFFFFF), name: "AppIcon-tinted.png")
