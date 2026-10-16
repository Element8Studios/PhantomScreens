import SwiftUI

/// Three short cards shown on first launch (and from Settings → Advanced).
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private struct Card {
        let symbol: String
        let title: String
        let text: String
    }

    private let cards = [
        Card(symbol: "viewfinder",
             title: "See Phantom in your space",
             text: "Point your camera at a door, window or outdoor opening. The app finds it, measures it and suggests the right screen."),
        Card(symbol: "hand.tap",
             title: "Tap to help",
             text: "If it picks the wrong opening, tap the one you want. You can also mark two corners yourself."),
        Card(symbol: "slider.horizontal.3",
             title: "Make it yours",
             text: "Everything starts chosen for you. Change the screen, closure, mesh or color, then send it to your local Phantom expert for a quote.")
    ]

    var body: some View {
        ZStack {
            Color.phantomNavy.ignoresSafeArea()
            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    if page < cards.count - 1 {
                        Button("Skip", action: onFinish)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 20)

                TabView(selection: $page) {
                    ForEach(cards.indices, id: \.self) { index in
                        VStack(spacing: 20) {
                            Spacer()
                            Image(systemName: cards[index].symbol)
                                .font(.system(size: 64, weight: .light))
                                .foregroundStyle(Color.phantomCyan)
                            Text(cards[index].title)
                                .font(.title.bold())
                                .multilineTextAlignment(.center)
                            Text(cards[index].text)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button {
                    if page < cards.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onFinish()
                    }
                } label: {
                    Text(page < cards.count - 1 ? "Next" : "Get Started")
                        .font(.headline)
                        .foregroundStyle(Color.phantomNavy)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
    }
}
