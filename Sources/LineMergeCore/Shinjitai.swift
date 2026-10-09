import Foundation

/// Japanese shinjitai that `Hant-Hans` leaves behind, mapped to simplified Chinese.
/// Kana is not in the table. `浄` maps to `净` (water radical); `済` maps to `济`.
/// The table is one source glyph to one target glyph and skips kokuji and
/// readings that would have to pick among several Chinese characters.
public func shinjitaiToSimplified(_ text: String) -> String {
    if text.isEmpty || shinjitaiMap.isEmpty { return text }
    var output = ""
    output.reserveCapacity(text.count)
    for character in text {
        if let mapped = shinjitaiMap[character] {
            output.append(mapped)
        } else {
            output.append(character)
        }
    }
    return output
}

private let shinjitaiPairs =
    "発发気气満满対对実实経经駅驿浜滨楽乐図图単单読读広广浄净従从様样検检総总値值変变弾弹嶋岛鉄铁郷乡両两済济" +
    "圧压応应桜樱県县営营円圆黒黑歩步拝拜剣剑砕碎亀龟竜龙亜亚悪恶仏佛仮假価价伝传児儿処处労劳勧劝収收売卖専专歳岁岡冈" +
    "巣巢巻卷帯带庁厅廃废徳德恵惠悩恼戦战抜拔択择拡扩挙举捜搜掲揭撃击斉齐斎斋晩晚暁晓書书東东栄荣権权樹树橋桥機机" +
    "歯齿歴历毎每沢泽況况涙泪渋涩渓溪滝泷溝沟滅灭漢汉漬渍潔洁濁浊濃浓瀬濑為为無无焼烧煙烟熱热犠牺獣兽畳叠療疗砲炮" +
    "確确稲稻穀谷穂穗積积穏稳窓窗筆笔節节築筑簡简粋粹約约紅红納纳純纯紙纸級级細细終终組组結结給给絵绘絶绝継继続续" +
    "維维綱纲網网綿绵緊紧線线編编練练縁缘縦纵縫缝縮缩績绩繊纤織织罰罚羅罗義义習习聖圣聞闻聴听職职脈脉脳脑腸肠臓脏" +
    "興兴舎舍舗铺艦舰芸艺葉叶蔵藏薬药蛍萤衆众術术衛卫衝冲裏里補补製制複复襲袭見见規规視视覧览親亲観观覚觉計计記记" +
    "設设訳译説说語语認认論论議议譲让護护豊丰貝贝負负財财買买費费資资質质車车転转軽轻輪轮輸输農农辺边連连進进違违" +
    "遠远選选還还郵邮釈释銭钱鉱矿銀银銅铜鋼钢録录鏡镜長长門门開开間间関关陸陆険险陽阳隊队階阶隣邻雑杂難难雲云電电" +
    "霊灵馬马駆驱験验驚惊魚鱼鳥鸟齢龄島岛髪发"

private let shinjitaiMap: [Character: Character] = {
    var map: [Character: Character] = [:]
    let characters = Array(shinjitaiPairs)
    var index = 0
    while index + 1 < characters.count {
        let source = characters[index]
        let target = characters[index + 1]
        if source != target {
            map[source] = target
        }
        index += 2
    }
    return map
}()
