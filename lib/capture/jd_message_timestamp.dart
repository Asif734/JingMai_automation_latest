/// JD chat clocks use China Standard Time, independently of the Mac timezone.
final jdMessageTimestampPattern = RegExp(
    r'(?:(?:20\d{2}[-/.])?\d{1,2}[-/.]\d{1,2}\s+)?\d{1,2}:\d{2}(?::\d{2})?');

DateTime? parseJdMessageTimestamp(String? text, DateTime capturedAt) {
  if (text == null) return null;
  final match = RegExp(
          r'(?:(?:(20\d{2})[-/.])?(\d{1,2})[-/.](\d{1,2})\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?')
      .firstMatch(text);
  if (match == null) return null;
  int? number(int group) => int.tryParse(match.group(group) ?? '');
  const offset = Duration(hours: 8);
  final utc = capturedAt.toUtc();
  final jdDay = utc.add(offset);
  final year = number(1) ?? jdDay.year;
  final month = number(2) ?? jdDay.month;
  final day = number(3) ?? jdDay.day;
  final hour = number(4)!;
  final minute = number(5)!;
  final second = number(6) ?? 0;
  final local = DateTime.utc(year, month, day, hour, minute, second);
  if (local.month != month ||
      local.day != day ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  var result = local.subtract(offset);
  if (number(1) == null &&
      result.difference(utc) > const Duration(minutes: 1)) {
    result = number(2) == null
        ? result.subtract(const Duration(days: 1))
        : DateTime.utc(year - 1, month, day, hour, minute, second)
            .subtract(offset);
  }
  return result;
}
