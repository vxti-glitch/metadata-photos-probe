import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/legal_documents.dart';

void main() {
  test('legacy and unknown providers retain existing legal texts', () {
    expect(
      LegalDocuments.privacyForProvider('Zlarp'),
      LegalDocuments.privacyPolicy,
    );
    expect(LegalDocuments.termsForProvider('Zlarp'), LegalDocuments.termsOfUse);
    expect(
      LegalDocuments.privacyForProvider('unknown'),
      LegalDocuments.privacyPolicy,
    );
  });
  test('Aurel test disclosures describe the actual activation boundaries', () {
    final privacy = LegalDocuments.privacyForProvider('Aurel Archive');
    final terms = LegalDocuments.termsForProvider('Aurel Archive');
    expect(privacy, contains('Supabase over HTTPS'));
    expect(privacy, contains('does not include your media'));
    expect(privacy, contains('hash of the license key'));
    expect(privacy, contains('no more than one hour'));
    expect(privacy, contains('does not cancel a subscription'));
    expect(terms, contains('Test purchases do not charge real money'));
    expect(terms, contains('two registered installations'));
    expect(
      terms,
      contains('signed iPhone'),
      reason: 'device acceptance must remain explicit',
    );
  });
}
