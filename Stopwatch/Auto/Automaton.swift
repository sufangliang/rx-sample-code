//
//  Automaton.swift
//  RxAutomaton
//
//  Created by Yasuhiro Inami on 2016-08-15.
//  Copyright © 2016 Yasuhiro Inami. All rights reserved.
//

import RxSwift
//import RxCocoa

//
// Terminology:
// Whenever the word "signal" or "(signal) producer" appears (derived from ReactiveCocoa),
// they mean "hot-observable" and "cold-observable".
// See also https://github.com/inamiy/ReactiveAutomaton (RAC version).
//

/// Deterministic finite state machine that receives "input"
/// and with "current state" transform to "next state" & "output (additional effect)".
public final class Automaton<State, Input>
{
    /// Basic state-transition function type.
    public typealias Mapping = (State, Input) -> State?

    /// Transducer (input & output) mapping with `Observable<Input>` (next-producer) as output,
    /// which **wraps additional effects and emit next input values**
    /// for automatic & continuous state-transitions.
    public typealias NextMapping = (State, Input) -> (State, Observable<Input>)?

    /// `Reply` signal that notifies either `.success` or `.failure` of state-transition on every input.
    public let replies: Observable<Reply<State, Input>>

    /// Current state.
    public let state: Variable<State>   // TODO: AnyProperty

    private let _replyObserver: AnyObserver<Reply<State, Input>>

    private var _disposeBag = DisposeBag()

    ///
    /// Initializer using `Mapping`.
    ///
    /// - Parameters:
    ///   - state: Initial state.
    ///   - input: `Observable<Input>` that automaton receives.
    ///   - mapping: Simple `Mapping` that designates next state only (no next-producer).
    ///
    public convenience init(state initialState: State, input inputSignal: Observable<Input>, mapping: @escaping Mapping)
    {
        self.init(state: initialState, input: inputSignal, mapping: _compose(_toNextMapping, mapping))
    }

    ///
    /// Initializer using `NextMapping`.
    ///
    /// - Parameters:
    ///   - state: Initial state.
    ///   - input: `Observable<Input>` that automaton receives.
    ///   - mapping: `NextMapping` that designates next state and also generates next-producer.
    ///   - strategy: `FlattenStrategy` that flattens next-producer generated by `NextMapping`.
    ///
    public init(state initialState: State, input inputSignal: Observable<Input>, mapping: @escaping NextMapping, strategy: FlattenStrategy = .merge)
    {
        let stateProperty = Variable(initialState)
        self.state = stateProperty // TODO: AnyProperty(stateProperty)

        let p = PublishSubject<Reply<State, Input>>()
        (self.replies, self._replyObserver) = (p.asObservable(), AnyObserver(eventHandler: p.asObserver().on))

        /// Recursive input-producer that sends inputs from `inputSignal`
        /// and also next-producers generated by `NextMapping`.
        func recurInputProducer(_ inputProducer: Observable<Input>, strategy: FlattenStrategy) -> Observable<Input>
        {
            return Observable<Input>.create { observer in
                let mappingSignal = inputProducer.withLatestFrom(stateProperty.asObservable()) { $0 }
                    .map { input, fromState in
                        return (input, fromState, mapping(fromState, input)?.1)
                    }

                let successSignal = mappingSignal
                    .filterMap { input, fromState, nextProducer in
                        return nextProducer.map { (input, fromState, $0) }
                    }
                    .flatMap(strategy) { input, fromState, nextProducer -> Observable<Input> in
                        return recurInputProducer(nextProducer, strategy: strategy)
                            .startWith(input)
                    }

                let failureSignal = mappingSignal
                    .filterMap { input, fromState, nextProducer -> Input? in
                        return nextProducer == nil ? input : nil
                    }

                let mergedProducer = Observable.of(failureSignal, successSignal).merge()

                return mergedProducer.subscribe(observer)
            }
        }

        let replySignal = recurInputProducer(inputSignal, strategy: strategy)
            .withLatestFrom(stateProperty.asObservable()) { $0 }
            .flatMap(.merge) { input, fromState -> Observable<Reply<State, Input>> in
                if let (toState, _) = mapping(fromState, input) {
                    return .just(.success(input, fromState, toState))
                }
                else {
                    return .just(.failure(input, fromState))
                }
            }
            .shareReplay(1)

        replySignal
            .flatMap(.merge) { reply -> Observable<State> in
                if let toState = reply.toState {
                    return .just(toState)
                }
                else {
                    return .empty()
                }
            }
            .bindTo(stateProperty)
            .addDisposableTo(_disposeBag)

        replySignal
            .subscribe(self._replyObserver)
            .addDisposableTo(_disposeBag)
    }

    deinit
    {
        self._replyObserver.onCompleted()
    }
}

// MARK: Private

private func _compose<A, B, C>(_ g: @escaping (B) -> C, _ f: @escaping (A) -> B) -> (A) -> C
{
    return { x in g(f(x)) }
}

private func _toNextMapping<State, Input>(toState: State?) -> (State, Observable<Input>)?
{
    if let toState = toState {
        return (toState, .empty())
    }
    else {
        return nil
    }
}

extension Observable {
    /// Naive implementation.
    fileprivate func filterMap<U>(transform: @escaping (Element) -> U?) -> Observable<U> {
        return self.map(transform).filter { $0 != nil }.map { $0! }
    }

    fileprivate func flatMap<U>(_ strategy: FlattenStrategy, transform: @escaping (Element) -> Observable<U>) -> Observable<U> {
        switch strategy {
            case .merge: return self.flatMap(transform)
            case .latest: return self.flatMapLatest(transform)
        }
    }
}
//
//// No idea why this is not in RxSwift but RxCocoa...
//extension ObservableType {
//    fileprivate func bindTo(_ variable: Variable<E>) -> Disposable {
//        return subscribe { e in
//            switch e {
//            case let .next(element):
//                variable.value = element
//            case let .error(error):
//                let error = "Binding error to variable: \(error)"
//                #if DEBUG
////                    rxFatalError(error)
//                #else
//                    print(error)
//                #endif
//            case .completed:
//                break
//            }
//        }
//    }
//}
