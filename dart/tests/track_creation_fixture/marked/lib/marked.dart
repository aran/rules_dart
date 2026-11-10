/// A class whose constructor call sites record where they are, when the
/// program is compiled with `--track-creation-locations`.
@pragma('track-creation-locations')
class Marked {
  Marked();
}
