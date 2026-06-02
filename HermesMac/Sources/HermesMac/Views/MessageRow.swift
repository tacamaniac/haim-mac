import SwiftUI

struct MessageRow: View {
    let message: Message
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.isUser { Spacer(minLength: 60) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                bubble
                if message.isStreaming {
                    streamingIndicator
                }
                if message.content.hasPrefix("⚠️"), let retry = onRetry {
                    Button("Retry", action: retry)
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                }
            }

            if !message.isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var bubble: some View {
        if message.content.isEmpty && message.isStreaming {
            // Waiting dots while the model is thinking
            ThinkingDots()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground, in: bubbleShape)
        } else {
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground, in: bubbleShape)
                .foregroundStyle(message.isUser ? .white : .primary)
        }
    }

    private var streamingIndicator: some View {
        Text("Hermes is typing…")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private var bubbleBackground: some ShapeStyle {
        message.isUser
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(.background.secondary)
    }

    private var bubbleShape: some Shape {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }
}

// MARK: - Thinking dots animation

struct ThinkingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .foregroundStyle(.secondary)
        .onAppear { startAnimation() }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
            withAnimation(.easeInOut(duration: 0.3)) {
                phase = (phase + 1) % 3
            }
        }
    }
}
