import Foundation

/// Japanese meeting utterances chosen to stress the things that actually break
/// machine translation of business speech, so backends can be compared on the
/// failure modes that matter rather than on easy sentences.
///
/// Coverage:
///   - set phrases with no literal English equivalent (お疲れ様です)
///   - dropped subjects that must be recovered from context
///   - keigo and humble forms that should become ordinary polite English
///   - business jargon (据え置き, 前倒し, 巻き取る)
///   - sentence-final negation and modality -- the SOV problem
///   - indirect refusals that read as agreement if translated literally
enum Fixtures {
    static let japaneseMeetingUtterances: [String] = [
        "お疲れ様です。",
        "よろしくお願いいたします。",
        "先週の件ですが、クライアントから修正の依頼が来ています。",
        "予算は据え置きで問題ありません。",
        "スケジュールを一週間前倒しできないか検討しています。",
        "その件は私の方で巻き取ります。",
        "確認したところ、まだ反映されていないようです。",
        "恐れ入りますが、明日までにご返信いただけますでしょうか。",
        "それはちょっと難しいかもしれません。",
        "結構です。",
        "承知いたしました。すぐに対応いたします。",
        "念のため、もう一度確認させていただけますか。",
        "こちらの認識違いでしたら申し訳ありません。",
        "前回の議事録に記載されている通りです。",
        "工数がかなりかかりそうなので、優先度を下げたいと考えています。",
        "部長に確認を取ってから、改めてご連絡します。",
        "今期中のリリースは見送る方向で調整しています。",
        "そこは追って詰めましょう。",
    ]
}
