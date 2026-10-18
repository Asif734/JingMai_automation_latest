bool customerIdentitiesMatch(String? observed, String expected) {
  return observed != null &&
      expected.trim().isNotEmpty &&
      expected.trim() != 'Unknown customer' &&
      expected.trim() != 'unknown' &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(expected.trim()) &&
      !expected.contains('…') &&
      !expected.contains('...') &&
      observed.trim() == expected.trim();
}

enum CustomerIdentityResolutionKind {
  exact,
  uniqueTrustedNearMatch,
  unmatched,
  ambiguous,
  invalid,
}

class CustomerIdentityResolution {
  const CustomerIdentityResolution({
    required this.observed,
    required this.kind,
    this.customer,
    this.candidates = const [],
  });

  final String observed;
  final CustomerIdentityResolutionKind kind;
  final String? customer;
  final List<String> candidates;

  bool get resolved => customer != null;
}

/// Reconciles an OCR sidebar identity with identities that were previously
/// proved by a captured conversation. This is deliberately narrow:
///
/// * exact identities always win;
/// * only `jd_...` IDs can be repaired;
/// * at most one insertion, deletion, or substitution is tolerated; and
/// * more than one possible owner is rejected as ambiguous.
///
/// The returned canonical identity must still pass the native exact AX-header
/// check before any capture or send. This function never creates a permanent
/// alias from OCR alone.
CustomerIdentityResolution resolveObservedCustomerIdentity(
  String observed,
  Iterable<String> trustedCustomers,
) {
  final raw = observed.trim();
  if (!_isCompleteCustomerIdentity(raw)) {
    return CustomerIdentityResolution(
      observed: raw,
      kind: CustomerIdentityResolutionKind.invalid,
    );
  }

  final trusted = trustedCustomers
      .map((value) => value.trim())
      .where(_isCompleteCustomerIdentity)
      .toSet();
  if (trusted.contains(raw)) {
    return CustomerIdentityResolution(
      observed: raw,
      customer: raw,
      kind: CustomerIdentityResolutionKind.exact,
    );
  }

  if (!RegExp(r'^jd_[A-Za-z0-9]{8,}$').hasMatch(raw)) {
    return CustomerIdentityResolution(
      observed: raw,
      kind: CustomerIdentityResolutionKind.unmatched,
    );
  }
  final near = trusted
      .where((candidate) =>
          RegExp(r'^jd_[A-Za-z0-9]{8,}$').hasMatch(candidate) &&
          (candidate.length - raw.length).abs() <= 1 &&
          _editDistanceAtMost(raw, candidate, 1))
      .toList(growable: false)
    ..sort();
  if (near.length == 1) {
    return CustomerIdentityResolution(
      observed: raw,
      customer: near.single,
      candidates: near,
      kind: CustomerIdentityResolutionKind.uniqueTrustedNearMatch,
    );
  }
  return CustomerIdentityResolution(
    observed: raw,
    candidates: near,
    kind: near.isEmpty
        ? CustomerIdentityResolutionKind.unmatched
        : CustomerIdentityResolutionKind.ambiguous,
  );
}

bool _isCompleteCustomerIdentity(String value) =>
    value.isNotEmpty &&
    value != 'Unknown customer' &&
    value != 'unknown' &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) &&
    !value.contains('…') &&
    !value.contains('...');

bool _editDistanceAtMost(String left, String right, int limit) {
  if ((left.length - right.length).abs() > limit) return false;
  var previous = List<int>.generate(right.length + 1, (index) => index);
  for (var leftIndex = 1; leftIndex <= left.length; leftIndex++) {
    final current = List<int>.filled(right.length + 1, 0);
    current[0] = leftIndex;
    var rowMinimum = current[0];
    for (var rightIndex = 1; rightIndex <= right.length; rightIndex++) {
      final substitution =
          left.codeUnitAt(leftIndex - 1) == right.codeUnitAt(rightIndex - 1)
              ? 0
              : 1;
      current[rightIndex] = [
        current[rightIndex - 1] + 1,
        previous[rightIndex] + 1,
        previous[rightIndex - 1] + substitution,
      ].reduce((a, b) => a < b ? a : b);
      if (current[rightIndex] < rowMinimum) rowMinimum = current[rightIndex];
    }
    if (rowMinimum > limit) return false;
    previous = current;
  }
  return previous.last <= limit;
}

bool customerSenderLabelMatches(String value, String customer) {
  final raw = value.trim();
  final expected = customer.trim();
  if (customerIdentitiesMatch(raw, expected)) return true;
  // Accept only a complete identity followed by whitespace and an entire
  // timestamp. A longer ID that happens to start with this ID is unrelated.
  if (!raw.startsWith('$expected ')) return false;
  final suffix = raw.substring(expected.length).trim();
  return RegExp(
          r'^(?:(?:20\d{2}[-/.])?\d{1,2}[-/.]\d{1,2}\s+)?\d{1,2}:\d{2}(?::\d{2})?$')
      .hasMatch(suffix);
}

/// Repairs OCR text only; it never repairs an AX identity or establishes an
/// alias. A unique saved customer AND an independently verified AX header must
/// agree. A different real saved account always wins over fuzzy similarity.
String reconcileOcrCustomerSenderLabel({
  required String observedLabel,
  required String verifiedAxCustomer,
  required Iterable<String> trustedCustomers,
}) {
  final match = RegExp(
    r'^(jd_[A-Za-z0-9]{8,})(\s+(?:(?:20\d{2}[-/.])?\d{1,2}[-/.]\d{1,2}\s+)?\d{1,2}:\d{2}(?::\d{2})?)?$',
  ).firstMatch(observedLabel.trim());
  if (match == null) return observedLabel;
  final observed = match.group(1)!;
  final saved = trustedCustomers.map((id) => id.trim()).toSet();
  if (!saved.contains(verifiedAxCustomer) || saved.contains(observed)) {
    return observedLabel;
  }
  final resolution = resolveObservedCustomerIdentity(observed, saved);
  if (resolution.kind !=
          CustomerIdentityResolutionKind.uniqueTrustedNearMatch ||
      !customerIdentitiesMatch(resolution.customer, verifiedAxCustomer)) {
    return observedLabel;
  }
  return '$verifiedAxCustomer${match.group(2) ?? ''}';
}
