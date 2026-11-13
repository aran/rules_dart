/// Calls [callback] with four values made from [first] and [second].
void call(void Function(int, int, int, int) callback, int first, int second) {
  callback(
      first, second, first + second, first * second - first * first + second);
}
