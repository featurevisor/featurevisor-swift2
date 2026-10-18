import Foundation

enum VariableMutationError: LocalizedError {
    case invalidOperation
    case missingValue
    case invalidPath
    case unsafeKey
    case expectedObject
    case expectedArray
    case rootRemove
    case arrayElementPath
    case invalidJump

    var errorDescription: String? {
        switch self {
        case .invalidOperation: return "Invalid variable mutation operation"
        case .missingValue: return "Variable mutation operation requires a value"
        case .invalidPath: return "Invalid variable mutation path"
        case .unsafeKey: return "Unsafe variable mutation key"
        case .expectedObject: return "Variable mutation expected an object"
        case .expectedArray: return "Variable mutation expected an array"
        case .rootRemove: return "Cannot remove the root variable value"
        case .arrayElementPath: return "Variable mutation before/after requires an array element path"
        case .invalidJump: return "Invalid variable override program jump"
        }
    }
}

private let unsafeMutationKeys = Set(["__proto__", "prototype", "constructor"])
private let mutationOperations = Set([
    "set", "append", "prepend", "appendUnique", "removeValue", "before", "after", "remove",
])

private func isPrimitive(_ value: AnyValue) -> Bool {
    switch value {
    case .string, .int, .bool, .null: return true
    case .double(let number): return number.isFinite
    case .array, .object: return false
    }
}

private func mutationValueEquals(_ lhs: AnyValue, _ rhs: AnyValue) -> Bool {
    switch (lhs, rhs) {
    case (.int(let left), .double(let right)): return Double(left) == right
    case (.double(let left), .int(let right)): return left == Double(right)
    default: return lhs == rhs
    }
}

private func validate(_ operation: VariableMutationOperation) throws {
    guard mutationOperations.contains(operation.op) else { throw VariableMutationError.invalidOperation }
    if operation.op != "remove", operation.value == nil { throw VariableMutationError.missingValue }
    if operation.op == "appendUnique" || operation.op == "removeValue" {
        guard let value = operation.value, isPrimitive(value) else { throw VariableMutationError.missingValue }
    }
    for part in operation.path {
        switch part {
        case .key(let key):
            if unsafeMutationKeys.contains(key) { throw VariableMutationError.unsafeKey }
        case .index(let index):
            if index < 0 { throw VariableMutationError.invalidPath }
        case .selector(let selector):
            if unsafeMutationKeys.contains(selector.property) { throw VariableMutationError.unsafeKey }
            if !selector.values.allSatisfy(isPrimitive) { throw VariableMutationError.invalidPath }
        }
    }
}

private func selectedIndex(_ values: [AnyValue], selector: VariableMutationSelector) -> Int? {
    values.firstIndex { candidate in
        guard case .object(let object) = candidate, let value = object[selector.property] else { return false }
        return isPrimitive(value) && selector.values.contains { mutationValueEquals($0, value) }
    }
}

private func updateArray(_ array: [AnyValue], operation: String, value: AnyValue) -> [AnyValue] {
    if operation == "removeValue" { return array.filter { !mutationValueEquals($0, value) } }
    if operation == "appendUnique", array.contains(where: { mutationValueEquals($0, value) }) { return array }
    return operation == "prepend" ? [value] + array : array + [value]
}

private func updateFinal(
    _ value: AnyValue,
    part: VariableMutationPathPart,
    operation: VariableMutationOperation
) throws -> AnyValue {
    if value == .null { return value }
    if (operation.op == "before" || operation.op == "after"), case .key = part {
        throw VariableMutationError.arrayElementPath
    }

    switch part {
    case .key(let key):
        guard case .object(var object) = value else { throw VariableMutationError.expectedObject }
        if operation.op == "remove" {
            object.removeValue(forKey: key)
            return .object(object)
        }
        guard let item = operation.value else { throw VariableMutationError.missingValue }
        if operation.op == "set" {
            object[key] = item
            return .object(object)
        }
        guard operation.op != "before", operation.op != "after" else {
            throw VariableMutationError.arrayElementPath
        }
        if operation.op == "removeValue", object[key] == nil || object[key] == .null { return value }
        let current: [AnyValue]
        if object[key] == nil || object[key] == .null {
            current = []
        } else if case .array(let array)? = object[key] {
            current = array
        } else {
            throw VariableMutationError.expectedArray
        }
        object[key] = .array(updateArray(current, operation: operation.op, value: item))
        return .object(object)

    case .index, .selector:
        guard case .array(var array) = value else { throw VariableMutationError.expectedArray }
        let index: Int?
        switch part {
        case .index(let value): index = value
        case .selector(let selector): index = selectedIndex(array, selector: selector)
        case .key: index = nil
        }
        guard let index else { return value }
        if operation.op == "remove" {
            guard array.indices.contains(index) else { return value }
            array.remove(at: index)
            return .array(array)
        }
        guard let item = operation.value else { throw VariableMutationError.missingValue }
        if operation.op == "set" {
            guard index <= array.count else { return value }
            if index == array.count { array.append(item) } else { array[index] = item }
            return .array(array)
        }
        if operation.op == "before" || operation.op == "after" {
            guard array.indices.contains(index) else { return value }
            array.insert(item, at: index + (operation.op == "after" ? 1 : 0))
            return .array(array)
        }
        guard array.indices.contains(index) else { return value }
        if array[index] == .null { return value }
        guard case .array(let nested) = array[index] else { throw VariableMutationError.expectedArray }
        array[index] = .array(updateArray(nested, operation: operation.op, value: item))
        return .array(array)
    }
}

private func updateAtPath(
    _ value: AnyValue,
    operation: VariableMutationOperation,
    offset: Int
) throws -> AnyValue {
    if offset == operation.path.count {
        if operation.op == "set" {
            guard let replacement = operation.value else { throw VariableMutationError.missingValue }
            return replacement
        }
        if operation.op == "remove" { throw VariableMutationError.rootRemove }
        if operation.op == "before" || operation.op == "after" { throw VariableMutationError.arrayElementPath }
        if value == .null { return value }
        guard case .array(let array) = value else { throw VariableMutationError.expectedArray }
        guard let item = operation.value else { throw VariableMutationError.missingValue }
        return .array(updateArray(array, operation: operation.op, value: item))
    }

    if offset == operation.path.count - 1 {
        return try updateFinal(value, part: operation.path[offset], operation: operation)
    }
    if value == .null { return value }

    let part = operation.path[offset]
    switch part {
    case .key(let key):
        guard case .object(var object) = value else { throw VariableMutationError.expectedObject }
        guard let child = object[key], child != .null else { return value }
        object[key] = try updateAtPath(child, operation: operation, offset: offset + 1)
        return .object(object)
    case .index(let index):
        guard case .array(var array) = value else { throw VariableMutationError.expectedArray }
        guard array.indices.contains(index), array[index] != .null else { return value }
        array[index] = try updateAtPath(array[index], operation: operation, offset: offset + 1)
        return .array(array)
    case .selector(let selector):
        guard case .array(var array) = value else { throw VariableMutationError.expectedArray }
        guard let index = selectedIndex(array, selector: selector), array[index] != .null else { return value }
        array[index] = try updateAtPath(array[index], operation: operation, offset: offset + 1)
        return .array(array)
    }
}

func applyVariableOperations(
    _ value: VariableValue,
    operations: [VariableMutationOperation]
) throws -> VariableValue {
    try operations.reduce(value) { current, operation in
        try validate(operation)
        return try updateAtPath(current, operation: operation, offset: 0)
    }
}
