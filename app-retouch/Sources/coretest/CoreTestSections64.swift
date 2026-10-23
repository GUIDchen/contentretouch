// §392：许可红线必须被测 —— 否则「只评测不入库」只是口号 ✗。
// 构造方式：一律**从 JSON 解析**得到模型对象 ✓（public 结构体的 memberwise init 是 internal，
// 跨模块用不了 ✗；而且这也更贴近真实用法：清单本来就是 JSON ✓）。
import Foundation
import RetouchCore

func runSections64() {
    head("64. 第三方模型许可把关：哪些可入库")
    func model(license: String?) -> CatalogModel? {
        let lic = license == nil ? "null" : ("{\"name\":\"" + license! + "\"}")
        let json = "{\"manifest_version\":1,\"models\":[{\"id\":\"x\",\"name\":\"X\","
                 + "\"files\":[{\"name\":\"a.zip\",\"url\":\"u\"}],\"license\":" + lic + "}]}"
        return ModelCatalog.decode(Data(json.utf8))?.models?.first
    }
    func ship(_ lic: String?) -> Bool { model(license: lic).map { ModelCatalog.isShippable($0) } ?? false }
    check("Apache-2.0 ⇒ 可入库", ship("Apache-2.0") == true, "true ✓")
    check("MIT ⇒ 可入库", ship("MIT") == true, "true ✓")
    check("CC BY 4.0 ⇒ 可入库", ship("CC BY 4.0") == true, "true ✓")
    check("non-commercial ⇒ 不可入库（只评测）",
          ship("Bria RMBG-1.4 License (non-commercial)") == false, "false ✓")
    check("CC BY-NC-SA ⇒ 不可入库", ship("CC BY-NC-SA 4.0") == false, "false ✓")
    check("AGPL-3.0 ⇒ 不可入库", ship("AGPL-3.0") == false, "false ✓")
    check("GPL-3.0 ⇒ 不可入库", ship("GPL-3.0") == false, "false ✓")
    check("许可缺失 ⇒ 不可入库（查不到就当不可用）", ship(nil) == false, "false ✓")
    check("清单可解析出模型与许可", model(license: "MIT")?.license?.name == "MIT", "MIT ✓")
}
