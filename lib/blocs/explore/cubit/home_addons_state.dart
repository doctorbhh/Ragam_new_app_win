import 'package:equatable/equatable.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';

abstract class HomeAddonsState extends Equatable {
  const HomeAddonsState();

  @override
  List<Object?> get props => [];
}

class HomeAddonsInitial extends HomeAddonsState {}

class HomeAddonsLoading extends HomeAddonsState {}

class HomeAddonsLoaded extends HomeAddonsState {
  final List<Section> sections;
  final String source; // 'spotify', 'ytmusic', or 'plugin'

  const HomeAddonsLoaded(this.sections, {this.source = 'plugin'});

  @override
  List<Object?> get props => [sections, source];
}

class HomeAddonsError extends HomeAddonsState {
  final String message;

  const HomeAddonsError(this.message);

  @override
  List<Object?> get props => [message];
}
