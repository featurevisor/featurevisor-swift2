import Foundation
import Featurevisor

func prepareSegmentGates(_ datafile: DatafileContent, definitions: [String: Any]) -> (datafile: DatafileContent, gates: [String: String]) {
    var result = datafile
    var gates: [String: String] = [:]
    for key in definitions.keys.sorted() {
        if result.segments[key] == nil,
           let raw = definitions[key], JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let segment = try? JSONDecoder().decode(Segment.self, from: data) {
            result.segments[key] = segment
        }
        var gate = "__featurevisor_segment_test__" + key
        while result.features[gate] != nil { gate += "_" }
        gates[key] = gate
        let raw: [String: Any] = [
            "bucketBy": "__segment_test__", "conditions": key,
            "traffic": [["key": "segment", "conditions": "*", "percentage": 100000]],
        ]
        result.features[gate] = try! JSONDecoder().decode(Feature.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    return (result, gates)
}

func preflightSegmentReferences(_ key: String, datafile: DatafileContent, definitions: [String: Any]) throws {
    let data = try JSONEncoder().encode(datafile)
    let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let features = root["features"] as? [String: Any] ?? [:]
    let variables = root["variables"] as? [String: Any] ?? [:]
    let segments = root["segments"] as? [String: Any] ?? [:]
    var pending: [(segment: String?, feature: String?, variable: String?)] = [(key, nil, nil)]
    var seen = Set<String>()
    func fail(_ message: String) -> NSError {
        NSError(domain: "FeaturevisorCLICheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    func walk(_ raw: Any?, legacyFeatures: Bool = false) {
        if let string = raw as? String {
            if string == "*" { return }
            if ["{", "[", "\""].contains(string.first(where: { !$0.isWhitespace }).map(String.init) ?? "") {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(string.utf8), options: [.fragmentsAllowed]) {
                    walk(parsed, legacyFeatures: legacyFeatures)
                }
            } else { pending.append(legacyFeatures ? (nil, string, nil) : (string, nil, nil)) }
        } else if let list = raw as? [Any] {
            for item in list { walk(item, legacyFeatures: legacyFeatures) }
        } else if let object = raw as? [String: Any] {
            if let variable = object["variable"] as? String { pending.append((nil, object["feature"] as? String, variable)) }
            else if let feature = object["feature"] as? String { pending.append((nil, feature, nil)) }
            else if object["attribute"] == nil {
                for name in ["and", "or", "not"] { if let children = object[name] { walk(children, legacyFeatures: legacyFeatures) } }
            }
        }
    }
    func selectors(_ entry: [String: Any]) {
        walk(entry["conditions"])
        walk(entry["segments"])
        walk(entry["requiredFeatures"], legacyFeatures: true)
    }
    var cursor = 0
    while cursor < pending.count {
        let item = pending[cursor]
        cursor += 1
        let id = String(decoding: try JSONEncoder().encode([item.segment, item.feature, item.variable]), as: UTF8.self)
        guard seen.insert(id).inserted else { continue }
        if let segment = item.segment {
            guard let definition = (definitions[segment] ?? segments[segment]) as? [String: Any],
                  let conditions = definition["conditions"] else { throw fail("segment \"\(segment)\" definition is missing or has no conditions") }
            walk(conditions)
        } else if let feature = item.feature {
            guard let definition = features[feature] as? [String: Any] else { throw fail("feature \"\(feature)\" is missing from the selected datafile") }
            if let variable = item.variable, (definition["variablesSchema"] as? [String: Any])?[variable] == nil {
                throw fail("feature variable \"\(feature).\(variable)\" is missing from the selected datafile")
            }
            selectors(definition)
            let entries = (definition["force"] as? [[String: Any]] ?? []) + (definition["traffic"] as? [[String: Any]] ?? [])
            for entry in entries { selectors(entry) }
            if let variable = item.variable {
                for entry in entries + (definition["variations"] as? [[String: Any]] ?? []) {
                    for override in (entry["variableOverrides"] as? [String: [[String: Any]]])?[variable] ?? [] { selectors(override) }
                }
            }
        } else if let variable = item.variable {
            guard let definition = variables[variable] as? [String: Any] else { throw fail("global variable \"\(variable)\" is missing from the selected datafile") }
            selectors(definition)
            for entry in (definition["overrides"] as? [[String: Any]] ?? []) + (definition["overrideProgram"] as? [[String: Any]] ?? []) { selectors(entry) }
            if let alias = definition["compose"] as? String { pending.append((nil, nil, alias)) }
            else {
                for entry in definition["compose"] as? [[String: Any]] ?? [] {
                    pending.append((nil, entry["feature"] as? String, entry["variable"] as? String))
                }
            }
        }
    }
}
