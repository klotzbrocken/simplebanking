import SwiftUI

// MARK: - Attention Inbox Sheet

struct AttentionInboxView: View {
    let cards: [AttentionCard]
    var onViewTransaction: ((String) -> Void)? = nil
    var onMarkAllRead: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Image(systemName: cards.isEmpty ? "bell" : "bell.badge.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(cards.isEmpty ? .secondary : .orange)
                Text("Attention Inbox")
                    .font(.headline)
                Spacer()
                if !cards.isEmpty {
                    Button("Gelesen") {
                        onMarkAllRead?()
                        dismiss()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            if cards.isEmpty {
                // Leerer Zustand — positives Ergebnis
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 42))
                        .foregroundColor(.sbGreenStrong)
                    Text("Heute nichts Auffälliges")
                        .font(.headline)
                    Text("Alle Umsätze sehen normal aus.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(cards) { card in
                            AttentionCardView(card: card) {
                                if let txId = card.relatedTxId {
                                    onViewTransaction?(txId)
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
        .frame(width: 440, height: 520)
        .background(Color.panelBackground)
    }
}

// MARK: - Single Card

private struct AttentionCardView: View {
    let card: AttentionCard
    let onAction: () -> Void

    private var accentColor: Color {
        switch card.priority {
        case 1: return .red
        case 2: return .orange
        default: return .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.type.iconName)
                .font(.system(size: 22))
                .foregroundColor(accentColor)
                .frame(width: 30, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(card.title)
                    .font(.body)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)

                Text(card.body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(card.detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Spacer(minLength: 8)

            if card.relatedTxId != nil {
                Button("Ansehen", action: onAction)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
        )
    }
}
