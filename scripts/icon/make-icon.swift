// Draws the bCompositor app icon: the macOS icon shape with a Bitcoin-orange gradient
// and a white "b". Usage: swift make-icon.swift out.png, then sips it down to each size in AppIcon.appiconset.
import AppKit

let args = CommandLine.arguments

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: an 824-point body inset 100 points, continuous corners, and a soft shadow beneath.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let colors = [CGColor(srgbRed: 0.10, green: 0.07, blue: 0.14, alpha: 1),
              CGColor(srgbRed: 0.62, green: 0.25, blue: 0.05, alpha: 1),
              CGColor(srgbRed: 0.97, green: 0.58, blue: 0.10, alpha: 1),
              CGColor(srgbRed: 1.00, green: 0.80, blue: 0.42, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.38, 0.72, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 140, y: 930), end: CGPoint(x: 900, y: 90), options: [])
ctx.restoreGState()

// The glyph, centred on the body.
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let base = NSFont.systemFont(ofSize: 620, weight: .heavy)
let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 620) ?? base
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
let text = NSAttributedString(string: "b", attributes: [.font: font, .foregroundColor: NSColor.white, .shadow: shadow])
let bounds = text.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesFontLeading])
let glyph = text.size()
text.draw(at: CGPoint(x: (1024 - glyph.width) / 2 - bounds.minX, y: 512 + 12 - glyph.height / 2 + font.descender / 2 * -0.0))

let out = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try! out.write(to: URL(fileURLWithPath: args[1]))
