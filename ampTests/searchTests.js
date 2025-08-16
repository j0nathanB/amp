// search.test.js
// Test suite for Apple Music-style search functionality

describe('Apple Music Search', () => {
 
 describe('Basic Prefix Matching', () => {
   test('matches single word prefixes', () => {
     expect(searchMatches('sun', 'Sun Ra')).toBe(true)
     expect(searchMatches('sun', 'Sunny Day Real Estate')).toBe(true)
     expect(searchMatches('sun', 'Sunflower')).toBe(true)
     expect(searchMatches('sun', 'The Sunset Strip')).toBe(true)
     expect(searchMatches('sun', 'Godspeed You! Black Emperor')).toBe(false)
   })

   test('matches multiple word prefixes', () => {
     expect(searchMatches('the a', 'The Avalanches')).toBe(true)
     expect(searchMatches('the a', 'The Cannonball Adderley Quartet')).toBe(false)
     expect(searchMatches('nat la', 'Natalia Lafourcade')).toBe(true)
     expect(searchMatches('arc fir', 'Arcade Fire')).toBe(true)
     expect(searchMatches('tay swi', 'Taylor Swift')).toBe(true)
   })

   test('requires ALL search terms to match', () => {
     expect(searchMatches('sun ra', 'Sun Ra')).toBe(true)
     expect(searchMatches('sun ra', 'Sunny Day Real Estate')).toBe(false)
     expect(searchMatches('real sun', 'Sunny Day Real Estate')).toBe(true) // order doesn't matter
   })

   test('does not match middle or end of words', () => {
     expect(searchMatches('car', 'Scarlett')).toBe(false)
     expect(searchMatches('car', 'Oscar Peterson')).toBe(false)
     expect(searchMatches('car', 'Carly Rae Jepsen')).toBe(true)
   })
 })

 describe('Single Character Search', () => {
   test('single character matches any word starting with that letter', () => {
     expect(searchMatches('e', 'Elvis')).toBe(true)
     expect(searchMatches('e', 'The Eagles')).toBe(true)
     expect(searchMatches('e', 'Missy Elliott')).toBe(true)
     expect(searchMatches('e', 'Duke Ellington')).toBe(true)
     expect(searchMatches('e', 'Bon Iver')).toBe(false)
   })
 })

 describe('Normalization - Case and Diacritics', () => {
   test('case insensitive matching', () => {
     expect(searchMatches('radiohead', 'Radiohead')).toBe(true)
     expect(searchMatches('RADIOHEAD', 'Radiohead')).toBe(true)
     expect(searchMatches('RaDiOhEaD', 'Radiohead')).toBe(true)
   })

   test('removes diacritics and accents', () => {
     expect(searchMatches('cafe', 'Café Tacuba')).toBe(true)
     expect(searchMatches('bjork', 'Björk')).toBe(true)
     expect(searchMatches('jose', 'José González')).toBe(true)
     expect(searchMatches('beyonce', 'Beyoncé')).toBe(true)
     expect(searchMatches('sigur ros', 'Sigur Rós')).toBe(true)
   })
 })

 describe('Article Handling', () => {
   test('searches work with or without articles', () => {
     expect(searchMatches('beatles', 'The Beatles')).toBe(true)
     expect(searchMatches('the beatles', 'The Beatles')).toBe(true)
     expect(searchMatches('rolling', 'The Rolling Stones')).toBe(true)
   })

   test('handles articles in multiple languages', () => {
     expect(searchMatches('pibes', 'Los Pibes Chorros')).toBe(true)
     expect(searchMatches('los pibes', 'Los Pibes Chorros')).toBe(true)
     expect(searchMatches('femme', 'La Femme')).toBe(true)
     expect(searchMatches('la femme', 'La Femme')).toBe(true)
   })
 })

 describe('Symbol Normalization', () => {
   test('dollar sign converts to s', () => {
     expect(searchMatches('kesha', 'Ke$ha')).toBe(true)
     expect(searchMatches('ke$ha', 'Ke$ha')).toBe(true)
     expect(searchMatches('keha', 'Ke$ha')).toBe(false) // $ becomes s, not removed
   })

   test('ampersand converts to and', () => {
     expect(searchMatches('black and blue', 'Black & Blue')).toBe(true)
     expect(searchMatches('black & blue', 'Black & Blue')).toBe(true)
     expect(searchMatches('simon and', 'Simon & Garfunkel')).toBe(true)
   })

   test('plus sign converts to and', () => {
     expect(searchMatches('blink and 182', 'blink+182')).toBe(true)
     expect(searchMatches('blink+182', 'blink+182')).toBe(true)
   })

   test('exclamation mark handling', () => {
     expect(searchMatches('pink', 'P!nk')).toBe(true)
     expect(searchMatches('p!nk', 'P!nk')).toBe(true)
     expect(searchMatches('godspeed you black', 'Godspeed You! Black Emperor')).toBe(true)
     expect(searchMatches('godspeed you! black', 'Godspeed You! Black Emperor')).toBe(true)
   })

   test('forward slash becomes space', () => {
     expect(searchMatches('ac dc', 'AC/DC')).toBe(true)
     expect(searchMatches('ac/dc', 'AC/DC')).toBe(true)
     expect(searchMatches('acdc', 'AC/DC')).toBe(true) // both parts concatenated
   })

   test('hyphen becomes space', () => {
     expect(searchMatches('jay z', 'Jay-Z')).toBe(true)
     expect(searchMatches('jay-z', 'Jay-Z')).toBe(true)
     expect(searchMatches('jayz', 'Jay-Z')).toBe(true)
     expect(searchMatches('twenty one', 'Twenty-One Pilots')).toBe(true)
   })

   test('periods are removed', () => {
     expect(searchMatches('rem', 'R.E.M.')).toBe(true)
     expect(searchMatches('r.e.m.', 'R.E.M.')).toBe(true)
     expect(searchMatches('run dmc', 'Run-D.M.C.')).toBe(true)
   })

   test('apostrophes are removed', () => {
     expect(searchMatches('dont', "Don't Stop Believin'")).toBe(true)
     expect(searchMatches("don't", "Don't Stop Believin'")).toBe(true)
     expect(searchMatches('guns n', "Guns N' Roses")).toBe(true)
   })
 })

 describe('Parenthetical Content', () => {
   test('parenthetical content is searchable', () => {
     expect(searchMatches('drake', 'Hotline Bling (feat. Drake)')).toBe(true)
     expect(searchMatches('feat drake', 'Hotline Bling (feat. Drake)')).toBe(true)
     expect(searchMatches('remix', 'Song Title (Remix)')).toBe(true)
     expect(searchMatches('bonus', 'Hidden Track [Bonus Track]')).toBe(true)
   })

   test('parentheses and brackets are ignored', () => {
     expect(searchMatches('hotline bling feat', 'Hotline Bling (feat. Drake)')).toBe(true)
     expect(searchMatches('song title remix', 'Song Title (Remix)')).toBe(true)
   })
 })

 describe('Number Handling', () => {
   test('numbers match literally', () => {
     expect(searchMatches('3', '3 Doors Down')).toBe(true)
     expect(searchMatches('3', 'Three Days Grace')).toBe(false)
     expect(searchMatches('three', 'Three Days Grace')).toBe(true)
     expect(searchMatches('three', '3 Doors Down')).toBe(false)
     expect(searchMatches('u2', 'U2')).toBe(true)
     expect(searchMatches('182', 'blink-182')).toBe(true)
   })
 })

 describe('Complex Queries', () => {
   test('handles complex multi-token searches', () => {
     expect(searchMatches('red hot', 'Red Hot Chili Peppers')).toBe(true)
     expect(searchMatches('hot chili', 'Red Hot Chili Peppers')).toBe(true)
     expect(searchMatches('red chili', 'Red Hot Chili Peppers')).toBe(true)
     expect(searchMatches('red pepper', 'Red Hot Chili Peppers')).toBe(false) // 'pepper' doesn't match 'Peppers'
   })

   test('word order does not matter for matching', () => {
     expect(searchMatches('swift taylor', 'Taylor Swift')).toBe(true)
     expect(searchMatches('day sunny real', 'Sunny Day Real Estate')).toBe(true)
     expect(searchMatches('roses guns', "Guns N' Roses")).toBe(true)
   })
 })

 describe('Category Independence', () => {
   // These would need a different function signature that includes category
   test('artist match does not imply song match', () => {
     const results = searchByCategory('arc fir', {
       artists: ['Arcade Fire'],
       songs: ['Wake Up', 'Rebellion (Lies)', 'The Suburbs'],
       albums: ['Funeral', 'The Suburbs', 'Reflektor']
     })
     
     expect(results.artists).toContain('Arcade Fire')
     expect(results.songs).toEqual([])
     expect(results.albums).toEqual([])
   })

   test('each category searches independently', () => {
     const results = searchByCategory('love', {
       artists: ['Love', 'Loveless'],
       songs: ['Love Story', 'Love Me Do', 'California Love'],
       albums: ['Love Songs', 'Endless Love', 'Love Deluxe']
     })
     
     expect(results.artists).toEqual(['Love', 'Loveless'])
     expect(results.songs).toEqual(['Love Story', 'Love Me Do'])
     expect(results.albums).toEqual(['Love Songs', 'Love Deluxe'])
   })
 })

 describe('Ranking', () => {
   test('exact matches come first', () => {
     const results = rankResults('sun', [
       'Sunflower',
       'Sun',
       'Sunny Day Real Estate',
       'Sun Ra',
       'Sun Kil Moon'
     ])
     
     expect(results[0]).toBe('Sun')
     // Rest should be alphabetical
     expect(results.slice(1)).toEqual([
       'Sun Kil Moon',
       'Sun Ra',
       'Sunflower',
       'Sunny Day Real Estate'
     ])
   })
 })

 describe('Edge Cases', () => {
   test('empty query returns false', () => {
     expect(searchMatches('', 'The Beatles')).toBe(false)
   })

   test('whitespace-only query returns false', () => {
     expect(searchMatches('   ', 'The Beatles')).toBe(false)
   })

   test('special characters only returns false', () => {
     expect(searchMatches('!!!', 'The Beatles')).toBe(false)
     expect(searchMatches('&&&', 'The Beatles')).toBe(false)
   })

   test('handles multiple spaces between words', () => {
     expect(searchMatches('the    beatles', 'The Beatles')).toBe(true)
   })
 })
})