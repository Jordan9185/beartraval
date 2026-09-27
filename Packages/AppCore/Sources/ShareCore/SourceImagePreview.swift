import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 分享與辨識畫面共用：來源縮圖可打開全螢幕，對照辨識錯誤。
public struct SourceImagePreview: View {
    let data: Data
    let title: String
    let maxHeight: CGFloat
    @State private var showing = false

    public init(data: Data, title: String = "來源圖片", maxHeight: CGFloat = 180) {
        self.data = data
        self.title = title
        self.maxHeight = maxHeight
    }

    public var body: some View {
        Button { showing = true } label: {
            VStack(spacing: 6) {
                if let image {
                    image.resizable().scaledToFit().frame(maxHeight: maxHeight).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Label("點一下放大圖片", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("放大\(title)")
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showing) { viewer }
        #else
        .sheet(isPresented: $showing) { viewer.frame(minWidth: 600, minHeight: 600) }
        #endif
    }

    private var image: Image? {
        #if canImport(UIKit)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }

    private var viewer: some View {
        NavigationStack {
            Group {
                #if canImport(UIKit)
                SourceImageZoom(data: data)
                #else
                ScrollView([.horizontal, .vertical]) { image }
                #endif
            }
            .background(.black)
            .navigationTitle(title)
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { showing = false } }
            }
            .safeAreaInset(edge: .bottom) {
                Text("雙指縮放、拖曳查看；雙擊放大或還原")
                    .font(.caption).foregroundStyle(.white).padding(8).frame(maxWidth: .infinity).background(.black)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#if canImport(UIKit)
private struct SourceImageZoom: View {
    let image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var settledOffset = CGSize.zero

    init(data: Data) { image = UIImage(data: data) }

    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale).offset(offset)
                    .accessibilityLabel("來源圖片")
                    .accessibilityIdentifier("sourceImageContent")
                    .accessibilityValue("\(Int((scale * 100).rounded()))%")
            }
        }
        .overlay {
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .gesture(MagnifyGesture().onChanged { value in
                        scale = min(8, max(1, settledScale * value.magnification))
                        offset = bounded(offset, in: geometry.size)
                    }.onEnded { _ in settledScale = scale; settledOffset = offset })
                    .simultaneousGesture(DragGesture().onChanged { value in
                        guard scale > 1 else { return }
                        offset = bounded(CGSize(width: settledOffset.width + value.translation.width,
                                                height: settledOffset.height + value.translation.height), in: geometry.size)
                    }.onEnded { _ in settledOffset = offset })
                    .onTapGesture(count: 2) {
                        scale = scale > 1 ? 1 : 3
                        settledScale = scale
                        offset = .zero
                        settledOffset = .zero
                    }
                    .onChange(of: geometry.size) { offset = bounded(offset, in: geometry.size); settledOffset = offset }
            }
            .accessibilityHidden(true)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sourceImageZoom")
    }

    /// 以實際圖片邊緣限制拖曳，長截圖放大後仍能上下查看，不拖進整片空白。
    private func bounded(_ proposed: CGSize, in viewport: CGSize) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
        let horizontal = max(0, (image.size.width * fit * scale - viewport.width) / 2)
        let vertical = max(0, (image.size.height * fit * scale - viewport.height) / 2)
        return CGSize(width: min(horizontal, max(-horizontal, proposed.width)),
                      height: min(vertical, max(-vertical, proposed.height)))
    }
}
#endif
