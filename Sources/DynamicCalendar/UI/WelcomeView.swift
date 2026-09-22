import SwiftUI

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                AdaptiveGlassButton(fallback: .icon(), action: onCollapse) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .accessibilityLabel("收起")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Spacer(minLength: 6)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 78, height: 78)
                Image(systemName: "calendar.day.timeline.left")
                    .font(.system(size: 35, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            Text(model.authorization == .denied || model.authorization == .restricted ? "需要日历访问权限" : "把一周，收进右上角")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .padding(.top, 22)

            Text(welcomeMessage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 10)

            HStack(spacing: 28) {
                FeatureItem(icon: "checkmark.shield", title: "自主", detail: "确认后添加事件")
                FeatureItem(icon: "rectangle.topthird.inset.filled", title: "无痕", detail: "平时完全隐藏")
                FeatureItem(icon: "pin", title: "置顶", detail: "需要时钉在前面")
            }
            .padding(.top, 32)

            Spacer(minLength: 18)

            if model.authorization == .requesting {
                ProgressView("正在等待系统授权…")
                    .controlSize(.small)
                    .frame(height: 36)
            } else if model.authorization == .denied || model.authorization == .restricted {
                VStack(spacing: 10) {
                    AdaptiveGlassButton(isProminent: true, controlSize: .large,
                        action: model.openCalendarPrivacySettings) { Text("打开系统设置") }

                    AdaptiveGlassButton(action: model.finishWelcomeWithoutRequesting) {
                        Text("先看看空白周历")
                    }
                }
            } else {
                VStack(spacing: 10) {
                    AdaptiveGlassButton(isProminent: true, controlSize: .large, action: {
                        Task { await model.requestCalendarAccess() }
                    }) {
                        Text("允许访问系统日历")
                            .frame(minWidth: 180)
                    }

                    AdaptiveGlassButton(action: model.finishWelcomeWithoutRequesting) {
                        Text("暂不允许")
                    }
                }
            }

            Text("授权后，把鼠标移到当前屏幕右上角即可再次唤醒。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 20)
                .padding(.bottom, 32)
        }
        .padding(.horizontal, 44)
    }

    private var welcomeMessage: String {
        if model.authorization == .denied || model.authorization == .restricted {
            return "系统目前不允许访问日历。你可以在“隐私与安全性 › 日历”中重新开启；Timepane 展示你选择的日历，并在你确认后添加新事件。"
        }
        return "Timepane 展示你选择的 Apple Calendar，支持在确认后添加新事件，不会修改或删除已有事件。"
    }
}

private struct FeatureItem: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.055)))
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: 112)
    }
}
