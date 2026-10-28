import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

part 'global_events_state.dart';

class GlobalEventsCubit extends Cubit<GlobalEventsState> {
  // ignore: unused_field
  final SettingsDAO _settingsDao;

  GlobalEventsCubit({required SettingsDAO settingsDao})
      : _settingsDao = settingsDao,
        super(GlobalEventsInitial());

  void checkForUpdates() {
    // Remote app release checks are disabled. Updates happen via plugin rollouts.
  }

  void showAlertDialog(String title, String content) {
    emit(AlertDialogState(title: title, content: content));
  }
}
