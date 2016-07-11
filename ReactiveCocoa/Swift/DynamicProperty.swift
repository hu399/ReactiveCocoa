import Foundation
import enum Result.NoError

/// Models types that can be represented in Objective-C (i.e., reference
/// types, including generic types when boxed via `AnyObject`).
private protocol ObjectiveCRepresentable {
	associatedtype Value
	static func extractValue(fromRepresentation representation: AnyObject) -> Value
	static func represent(value value: Value) -> AnyObject
}

/// Wraps a `dynamic` property, or one defined in Objective-C, using Key-Value
/// Coding and Key-Value Observing.
///
/// Use this class only as a last resort! `MutableProperty` is generally better
/// unless KVC/KVO is required by the API you're using (for example,
/// `NSOperation`).
public final class DynamicProperty<Value>: MutablePropertyType {
	private weak var object: NSObject?
	private let keyPath: String

	private let extractValue: AnyObject -> Value
	private let represent: Value -> AnyObject

	/// The current value of the property, as read and written using Key-Value
	/// Coding.
	public var value: Value? {
		get {
			return object?.valueForKeyPath(keyPath).map(extractValue)
		}

		set(newValue) {
			object?.setValue(newValue.map(represent), forKeyPath: keyPath)
		}
	}

	/// A producer that will create a Key-Value Observer for the given object,
	/// send its initial value then all changes over time, and then complete
	/// when the observed object has deallocated.
	///
	/// By definition, this only works if the object given to init() is
	/// KVO-compliant. Most UI controls are not!
	public var producer: SignalProducer<Value?, NoError> {
		let producer = object.map { object in
			return object.rac_valuesForKeyPath(keyPath, observer: nil)
				.toSignalProducer()
				.map { [extractValue = self.extractValue] in $0.map(extractValue) }
				.flatMapError { error -> SignalProducer<Value, NoError> in
					return SignalProducer.empty.on(completed: {
						fatalError("Received unexpected error from KVO signal: \(error)")
					})
				}
		}

		return producer ?? .empty
	}

	public var signal: Signal<Value?, NoError> {
		var signal: Signal<Value, NoError>!
		producer.startWithSignal { innerSignal, _ in signal = innerSignal }
		return signal
	}

	/// Initializes a property that will observe and set the given key path of
	/// the given object. `object` must support weak references!
	private init<Representatable: ObjectiveCRepresentable where Representatable.Value == Value>(object: NSObject?, keyPath: String, representable: Representatable.Type) {
		self.object = object
		self.keyPath = keyPath

		self.extractValue = Representatable.extractValue
		self.represent = Representatable.represent

		objc_setAssociatedObject(object,
		                         UnsafePointer(Unmanaged.passUnretained(self).toOpaque()),
		                         self,
		                         .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
	}
}

extension DynamicProperty where Value: _ObjectiveCBridgeable {
	/// Initializes a property that will observe and set the given key path of
	/// the given object, where `Value` is a value type that is bridgeable
	/// to Objective-C.
	///
	/// `object` must support weak references!
	public convenience init(object: NSObject?, keyPath: String) {
		self.init(object: object, keyPath: keyPath, representable: BridgeableRepresentation.self)
	}
}

extension DynamicProperty where Value: AnyObject {
	/// Initializes a property that will observe and set the given key path of
	/// the given object, where `Value` is a reference type that can be
	/// represented directly in Objective-C via `AnyObject`.
	///
	/// `object` must support weak references!
	public convenience init(object: NSObject?, keyPath: String) {
		self.init(object: object, keyPath: keyPath, representable: DirectRepresentation.self)
	}
}

/// Represents values in Objective-C directly, via `AnyObject`.
private struct DirectRepresentation<Value: AnyObject>: ObjectiveCRepresentable {
	static func extractValue(fromRepresentation representation: AnyObject) -> Value {
		return representation as! Value
	}

	static func represent(value value: Value) -> AnyObject {
		return value
	}
}

/// Represents values in Objective-C indirectly, via bridging.
private struct BridgeableRepresentation<Value: _ObjectiveCBridgeable>: ObjectiveCRepresentable {
	static func extractValue(fromRepresentation representation: AnyObject) -> Value {
		let object = representation as! Value._ObjectiveCType
		var result: Value?
		Value._forceBridgeFromObjectiveC(object, result: &result)
		return result!
	}

	static func represent(value value: Value) -> AnyObject {
		return value._bridgeToObjectiveC()
	}
}
