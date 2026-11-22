//
//  GateView.swift
//  卡密激活弹窗 —— SwiftUI 实现
//
//  与 TrollInstallerX 的做法一致：SwiftUI TextField + 正常视图层级，
//  由 UIHostingController 承载后 present 出来。
//  这样可以避开 UIKit 手写弹窗在 iOS 14 上出现的崩溃。
//

import SwiftUI

struct GateView: View {
    var initialMessage: String
    var onSuccess: () -> Void

    @State private var kami: String = ""
    @State private var message: String = ""
    @State private var isError: Bool = true
    @State private var busy: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("激活授权")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(red: 0.13, green: 0.16, blue: 0.20))

                Text("一机一码，激活后可在本机使用")
                    .font(.system(size: 12))
                    .foregroundColor(Color(white: 0.5))

                TextField("WVF-XXXXX-XXXXX-XXXXX", text: $kami)
                    .textFieldStyle(PlainTextFieldStyle())
                    .multilineTextAlignment(.center)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(red: 0.95, green: 0.97, blue: 0.98))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(red: 0.88, green: 0.91, blue: 0.93), lineWidth: 1)
                    )
                    .padding(.horizontal, 4)

                HStack(spacing: 10) {
                    Button(action: pasteKey) {
                        Text("粘贴卡密")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(red: 0.52, green: 0.57, blue: 0.62)))
                            .foregroundColor(.white)
                    }

                    Button(action: activate) {
                        Text(busy ? "验证中…" : "激活")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 10)
                                            .fill(Color(red: 0.20, green: 0.55, blue: 0.90)))
                            .foregroundColor(.white)
                    }
                    .disabled(busy)
                }

                Text(message.isEmpty ? initialMessage : message)
                    .font(.system(size: 11.5))
                    .foregroundColor(isError ? Color(red: 0.85, green: 0.25, blue: 0.25)
                                             : Color(white: 0.5))
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 32)

                Text("卡密可先在微信里复制，再点「粘贴卡密」\n激活成功后本页自动关闭")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(white: 0.55))
                    .multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(maxWidth: 330)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
            .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 8)
            .padding(.horizontal, 28)
        }
    }

    private func pasteKey() {
        guard let s = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            isError = true
            message = "剪贴板是空的，请先复制卡密"
            return
        }
        kami = s.uppercased()
        isError = false
        message = "已粘贴，点「激活」"
    }

    private func activate() {
        let key = kami.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            isError = true
            message = "请先输入或粘贴卡密"
            return
        }

        busy = true
        isError = false
        message = "正在验证…"

        WVFLicense.shared().activate(withKey: key) { ok, msg in
            DispatchQueue.main.async {
                busy = false
                if ok {
                    isError = false
                    message = msg ?? "激活成功"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        onSuccess()
                    }
                } else {
                    isError = true
                    message = msg ?? "激活失败"
                }
            }
        }
    }
}

/// 供 Objective-C 调用的入口
@objc class WVFGateHost: NSObject {
    @objc static func makeViewController(_ message: String,
                                        onSuccess: @escaping @convention(block) () -> Void) -> UIViewController {
        let root = GateView(initialMessage: message, onSuccess: onSuccess)
        let host = UIHostingController(rootView: root)
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        host.view.backgroundColor = .clear
        return host
    }
}
