# Apple Music Search Feature Specification

## Core Search Behavior

### 1. Prefix Token Matching
- Search terms match the **beginning of words only**, not middle or end
- Each space-separated search term must match the beginning of at least one word in the result
- Word order in query doesn't affect matching, only ranking
- ALL search terms must match (implicit AND logic)

**Examples:**
- "the a" → matches "The Avalanches" ✓
- "the a" → does NOT match "The Cannonball Adderley Quartet" ✗
- "nat la" → matches "Natalia Lafourcade" ✓
- "sun" → matches "Sun Ra", "Sunny Day Real Estate", "Sunflower" ✓

### 2. Character Requirements
- **Single character**: Returns all results where first word begins with that letter
- **Two+ characters**: Initiates normal prefix matching rules
- Example: "e" returns all artists/songs/albums starting with 'E', while "el" matches "Elvis", "Missy Elliot"

### 3. Normalization Rules

**Applied to both search queries AND stored content:**

#### Text Normalization
- Convert to lowercase
- Remove diacritics/accents: "café" → "cafe", "Björk" → "bjork"
- Strip articles in all languages: "The Beatles" also matched by "beatles"
  - English: "the", "a", "an"
  - Spanish: "el", "la", "los", "las"
  - French: "le", "la", "les"
  - German: "der", "die", "das"
  - (Additional languages as needed)

#### Symbol Handling
- **Conversions:**
  - "$" → "s": "Ke$ha" → "kesha"
  - "&" → "and": "Black & Blue" → "black and blue"
  - "+" → "and": "blink+182" → "blink and 182"
  - "@" → "at": "Deadmau5 @ Play" → "deadmau5 at play"
  - "!" → "i": "P!nk" → "pink"
  
- **Removals/Spaces:**
  - "/" → space: "AC/DC" → "ac dc"
  - "-" → space: "Jay-Z" → "jay z"
  - "." → removed: "R.E.M." → "rem"
  - "'" → removed: "Don't" → "dont"
  - Other punctuation (?,!,:,;) → removed

#### Parenthetical Content
- Parentheses and brackets are removed but content remains searchable
- "(feat. Drake)" → "feat drake"
- "[Bonus Track]" → "bonus track"

### 4. Category-Specific Matching

**Each category searches independently against its own fields:**
- **Artists**: Matches against artist name only
- **Albums**: Matches against album title only
- **Songs**: Matches against song title only

**No cascade matching:** An artist matching "arcade fire" does NOT cause their songs to appear unless the song titles themselves match the search query.

### 5. Result Ranking

Within each category, results are ordered by:
1. **Exact matches first** (entire query equals entire result)
2. **Prefix matches** in alphabetical order

**Example for query "sun":**
1. Sun (exact match)
2. Sun Kil Moon (prefix, alphabetical)
3. Sun Ra (prefix, alphabetical)
4. Sunflower (prefix, alphabetical)
5. Sunny Day Real Estate (prefix, alphabetical)

### 6. Performance Considerations

- **Debouncing**: Wait for pause in typing before executing search (typically 300-500ms)
- **No maximum results**: All matches returned per category
- **Minimum query length**: 1 character

## Implementation Example

```pseudocode
function searchMatches(query, targetText):
  normalizedQuery = normalize(query)
  normalizedTarget = normalize(targetText)
  
  queryTokens = normalizedQuery.split(" ")
  targetTokens = normalizedTarget.split(" ")
  
  for each queryToken in queryTokens:
    matchFound = false
    for each targetToken in targetTokens:
      if targetToken.startsWith(queryToken):
        matchFound = true
        break
    if not matchFound:
      return false
  
  return true

function normalize(text):
  text = lowercase(text)
  text = removeDiacritics(text)
  text = replaceSymbols(text)  // $ → s, & → and, etc.
  text = removePunctuation(text)
  text = removeArticles(text)  // optional, only if at beginning
  text = removeExtraSpaces(text)
  return text
```

## Search Examples

| Query | Finds | Doesn't Find |
|-------|-------|--------------|
| "arc fir" | Arcade Fire (artist) | "Funeral" by Arcade Fire (album) |
| "drake" | "Hotline Bling (feat. Drake)" | "God's Plan" by Drake |
| "ac dc" | AC/DC | Acadia |
| "rem" | R.E.M. | Supreme |
| "beatles" | The Beatles | Beatles songs (unless "Beatles" in title) |
| "u2" | U2 | YouTube |
| "3 do" | 3 Doors Down | Three Days Grace |

## Edge Cases

- Empty query: Do nothing
- No results: Display "No results found" per category
- Special characters only: Treat as empty query
- Numbers: Match literally ("3" matches "3 Doors Down", not "Three Doors Down")