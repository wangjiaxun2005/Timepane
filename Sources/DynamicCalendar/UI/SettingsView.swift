import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AdaptiveGlassButton(fallback: .icon(), action: { model.route = .calendar }) {
                    Image(systemName: "chevron.left")
                        .frame(width: 20, height: 20)
                }
                .accessibilityLabel("返回周历")

                Text("设置")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(permissionLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.authorization.canReadEvents ? Color.green : Color.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.055)))
            }
            .padding(.horizontal, 16)
            .frame(height: 56)

            Divider().opacity(0.65)

            ScrollView {
                VStack(spacing: 14) {
                    calendarSection
                }
                .padding(16)
            }

            Divider().opacity(0.65)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Timepane 0.1")
                        .font(.system(size: 12, weight: .medium))
                    Text("查看日程 · 确认后添加事件")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AdaptiveGlassButton(action: onQuit) { Text("退出 Timepane") }
                    .tint(.red)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
        }
    }

    private var calendarSection: some View {
        SettingsCard(title: "显示的日历", icon: "calendar") {
            if model.authorization.canReadEvents {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.calendars) { calendar in
                        CalendarToggleRow(calendar: calendar) { isEnabled in
                            model.setCalendarEnabled(calendar.id, isEnabled: isEnabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("尚未获得完整日历权限")
                            .font(.system(size: 13, weight: .medium))
                        Text("读取并展示系统日历需要此权限。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AdaptiveGlassButton(action: model.openCalendarPrivacySettings) {
                        Text("打开系统设置")
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var permissionLabel: String {
        switch model.authorization {
        case .fullAccess: return "已授权"
        case .requesting: return "请求中"
        case .notDetermined: return "未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(cornerRadius: 13)
    }
}

private struct CalendarToggleRow: View {
    let calendar: CalendarSource
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: calendar.colorHex))
                .frame(width: 9, height: 9)

            Text(calendar.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if !calendar.isWritable {
                    Text("只读")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 28, alignment: .trailing)

            Toggle("", isOn: Binding(get: { calendar.isEnabled }, set: onChange))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }
}
