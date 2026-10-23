// §435 方向 6：槽位推断必须被测（否则界面又会退回到"segmentation ⇒ sam，其余 ⇒ faceparse"✗）。
import Foundation
import RetouchCore

func runSections71() {
    head("71. 模型槽位推断（按 id/category 关键词）")
    func m(_ id: String, _ cat: String) -> CatalogModel? {
        let json = "{\"models\":[{\"id\":\"" + id + "\",\"name\":\"X\",\"category_id\":\"" + cat + "\"}]}"
        return ModelCatalog.decode(Data(json.utf8))?.models?.first
    }
    func slot(_ id: String, _ cat: String) -> String {
        m(id, cat).flatMap { ModelCatalog.inferPlacement($0) }?.slot ?? "nil"
    }
    check("ddcolor/enhancement ⇒ ddcolor", slot("ddcolor", "enhancement") == "ddcolor", slot("ddcolor", "enhancement"))
    check("gfpgan/restoration ⇒ gfpgan", slot("gfpgan", "restoration") == "gfpgan", slot("gfpgan", "restoration"))
    check("lama/inpainting ⇒ lama", slot("lama", "inpainting") == "lama", slot("lama", "inpainting"))
    check("face_parsing/segmentation ⇒ faceparse（解析优先于 sam）",
          slot("face_parsing", "segmentation") == "faceparse", slot("face_parsing", "segmentation"))
    check("mobilesam/segmentation ⇒ sam", slot("mobilesam", "segmentation") == "sam", slot("mobilesam", "segmentation"))
    check("未知模型 ⇒ nil（宁可让用户手选，也不猜错）",
          m("some-unknown-thing", "llm").flatMap { ModelCatalog.inferPlacement($0) } == nil, "nil ✓")
}
