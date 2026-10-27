import 'package:flutter_test/flutter_test.dart';
import 'package:metadata_editor/legal_documents.dart';

void main() {
  test('live Aurel legal copy is independent from test and Zlarp', () {
    final privacy = LegalDocuments.privacyForProvider(
      'Aurel Archive',
      environment: 'live',
    );
    final terms = LegalDocuments.termsForProvider(
      'Aurel Archive',
      environment: 'live',
    );
    expect(privacy, LegalDocuments.aurelLivePrivacy);
    expect(privacy, contains('live license service'));
    expect(terms, contains('own compatible signing tool'));
    expect(terms, contains('Monthly access'));
    expect(terms, contains('Lifetime access'));
    expect(terms, isNot(contains('Test purchases do not charge real money')));
    expect(privacy, contains(LegalDocuments.liveLegalVersion));
    expect(terms, contains(LegalDocuments.liveLegalVersion));
    expect(
      LegalDocuments.termsForProvider('Zlarp', environment: 'live'),
      LegalDocuments.termsOfUse,
    );
    expect(
      LegalDocuments.termsForProvider('Aurel Archive', environment: 'test'),
      LegalDocuments.aurelTestTerms,
    );
  });
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
