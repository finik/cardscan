import 'package:flutter_test/flutter_test.dart';

import 'package:card_scan/models.dart';

void main() {
  test('card codes from filenames', () {
    expect(cardCodeFromFilename('5H.jpg'), '5H');
    expect(cardCodeFromFilename('AS.jpg'), 'AS');
    expect(cardCodeFromFilename('10D_2.jpg'), '10D');
    expect(cardCodeFromFilename('joker.jpg'), isNull);
  });

  test('completed cards ignore keep-both suffix', () {
    final listing = DeckListing(
      deck: 'Vikings',
      cards: ['AS.jpg', '5H_2.jpg', '10D.jpg'],
      back: const [],
      box: const [],
      extras: const [],
    );
    expect(listing.completedCardCodes, {'AS', '5H', '10D'});
  });
}
