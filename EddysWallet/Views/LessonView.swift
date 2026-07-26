import SwiftUI

struct LessonView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lessonIndex = 2

    private let lessons = [
        (title: "Your virtual balance", icon: "wallet.pass", color: EW.Color.primary, text: "A balance shows the pretend dollars that have been accepted in your wallet. Added dollars make it go up. Dollars recorded as used make it go down."),
        (title: "Making a plan", icon: "calendar", color: EW.Color.gold500, text: "An allowance is a plan for when virtual dollars may be added. You can think about what to save and what to use."),
        (title: "Borrow and repay", icon: "hand.raised", color: EW.Color.peach500, text: "A loan means your parent gives you virtual dollars to use now. You can give them back a little at a time. Each repayment lowers what is left."),
        (title: "Cards and payments", icon: "creditcard", color: EW.Color.green700, text: "Adults may use real-world payment methods. Eddie's Wallet does not connect to one and never moves real money.")
    ]

    private var lesson: (title: String, icon: String, color: Color, text: String) { lessons[lessonIndex] }

    var body: some View {
        NavigationStack {
            VStack(spacing: EW.Space.five) {
                ScrollView {
                    VStack(alignment: .leading, spacing: EW.Space.five) {
                        HStack {
                            Text("Starter lessons")
                                .font(EW.Font.captionUpper)
                                .foregroundStyle(EW.Color.textTertiary)
                            Spacer()
                            Text("\(lessonIndex + 1) of \(lessons.count)")
                                .font(EW.Font.caption)
                                .foregroundStyle(EW.Color.textSecondary)
                        }

                        VStack(spacing: EW.Space.three) {
                            IconBadge(lesson.icon, foreground: EW.Color.white, background: lesson.color, size: 82)
                            Text(lesson.title)
                                .font(EW.Font.display)
                                .foregroundStyle(EW.Color.white)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, EW.Space.seven)
                        .padding(.horizontal, EW.Space.five)
                        .background(lesson.color, in: RoundedRectangle(cornerRadius: EW.Radius.extraLarge, style: .continuous))

                        Text(lesson.text)
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(lessonIndex == 2
                             ? "Right now, Eddie has US$6.00 left to repay from a US$10.00 virtual loan."
                             : "These lessons are for practice. Finishing a lesson never creates or changes a money event.")
                            .font(EW.Font.body)
                            .foregroundStyle(EW.Color.textSecondary)

                        Text("Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.")
                            .font(EW.Font.caption)
                            .foregroundStyle(EW.Color.textTertiary)
                    }
                    .padding(EW.Space.screenMargin)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                HStack(spacing: EW.Space.two) {
                    ForEach(lessons.indices, id: \.self) { index in
                        Circle()
                            .fill(index <= lessonIndex ? lesson.color : EW.Color.ink100)
                            .frame(width: index == lessonIndex ? 18 : 12, height: index == lessonIndex ? 18 : 12)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: lessonIndex)

                Button(lessonIndex == lessons.count - 1 ? "Done" : "Continue") {
                    if lessonIndex < lessons.count - 1 {
                        lessonIndex += 1
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, EW.Space.screenMargin)
            }
            .background(EW.Color.appBackground)
            .navigationTitle("Lesson")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

#Preview("Lesson") {
    LessonView()
}
