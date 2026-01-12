import traceback
from sentence_transformers import SentenceTransformer
from sklearn.metrics.pairwise import cosine_similarity
import numpy as np
import re
from collections import Counter
import os
import sys

# Global variables to store singleton instances
_model = None
_initialized = False


def compare_all_statements(input_statements, output_statements):
    """
    Batch process all statement comparisons in parallel,
    optimizing for available GPU resources.

    Args:
        input_statements: List of input statement strings
        output_statements: List of output statement strings

    Returns:
        List of dictionaries with comparison results
    """
    try:
        # Load model once for all comparisons
        model = _get_model()

        # Determine optimal number of workers based on available VRAM
        num_workers = determine_optimal_workers()
        print(f"Using {num_workers} workers for batch comparison")

        # Create all statement pairs to compare
        comparison_pairs = [(i, o) for i in input_statements for o in output_statements]
        total_comparisons = len(comparison_pairs)
        print(f"Processing {total_comparisons} statement comparisons")

        # Process in batches using thread pool
        import concurrent.futures
        import time

        results = []
        start_time = time.time()

        # Pre-compute embeddings for all statements to avoid redundant encoding
        print("Pre-computing embeddings for all statements...")
        all_statements = input_statements + output_statements
        statement_embeddings = {}

        # Use batching for encoding to optimize GPU usage
        batch_size = 32  # Optimal batch size depends on GPU memory
        for i in range(0, len(all_statements), batch_size):
            batch = all_statements[i : i + batch_size]
            batch_embeddings = model.encode(batch)
            for j, stmt in enumerate(batch):
                statement_embeddings[stmt] = batch_embeddings[j]

        # Process comparisons in parallel
        with concurrent.futures.ThreadPoolExecutor(max_workers=num_workers) as executor:
            # Submit all comparison tasks
            future_to_pair = {
                executor.submit(
                    process_comparison_pair, pair[0], pair[1], statement_embeddings
                ): pair
                for pair in comparison_pairs
            }

            # Collect results as they complete
            for future in concurrent.futures.as_completed(future_to_pair):
                pair = future_to_pair[future]
                try:
                    result = future.result()
                    result["statement1"] = pair[0]
                    result["statement2"] = pair[1]
                    results.append(result)
                except Exception as exc:
                    print(f"Error processing comparison for {pair}: {exc}")
                    # Add a placeholder error result
                    results.append(
                        {
                            "statement1": pair[0],
                            "statement2": pair[1],
                            "error": str(exc),
                            "basic_score": 0,
                            "combined_score": 0,
                        }
                    )

        elapsed_time = time.time() - start_time
        comparisons_per_second = total_comparisons / elapsed_time
        print(f"Batch processing completed in {elapsed_time:.2f} seconds")
        print(
            f"Average processing speed: {comparisons_per_second:.2f} comparisons per second"
        )

        return results

    except Exception as e:
        print(f"Error in batch comparison: {str(e)}")
        return [{"error": str(e)}]


def determine_optimal_workers():
    """
    Determine optimal number of worker threads based on available VRAM.
    Defaults to CPU count on macOS or when detection fails.

    Returns:
        int: Number of worker threads to use
    """
    try:
        # Skip GPU detection on macOS
        if sys.platform == "darwin":
            cpu_cores = os.cpu_count() or 4
            return max(1, cpu_cores - 1)

        # Try to detect NVIDIA GPU and available VRAM using nvidia-smi
        import subprocess
        import re

        # Get GPU info using nvidia-smi
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=memory.total,memory.used",
                "--format=csv,nounits,noheader",
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Parse output to get available VRAM
        gpu_info = result.stdout.strip().split("\n")
        available_vram = []

        for line in gpu_info:
            total, used = map(int, line.split(","))
            available = total - used
            available_vram.append(available)

        if not available_vram:
            # Default to 4 workers if no GPU info is available
            return 4

        # Calculate workers based on available VRAM (1GB per worker, using 80% of free VRAM)
        # 1GB = 1024 MB
        total_available = sum(available_vram)
        workers = int((total_available * 0.8) / 1024)

        # Ensure at least 1 worker but no more than 16
        return max(1, min(16, workers))

    except Exception as e:
        # If detection fails, default to a reasonable number
        print(f"Could not determine GPU memory: {str(e)}. Defaulting to 4 workers.")
        return 4


def process_comparison_pair(statement1, statement2, precomputed_embeddings=None):
    """
    Process a single comparison pair, optionally using precomputed embeddings.
    This is the main function called by the worker processes.
    """
    try:
        # Print a message so we can see this is being called
        print(
            f"Processing comparison: '{statement1[:20]}...' vs '{statement2[:20]}...'"
        )

        # Get similarity score using precomputed embeddings if available
        if precomputed_embeddings is not None:
            # Use precomputed embeddings logic
            pass

        # If no precomputed embeddings, get all scores from scratch
        scores = get_alternative_similarity_scores(statement1, statement2)

        # Extract everything we need
        basic_score = scores.get("standard_similarity", 0)
        combined_score = scores.get("combined_score", 0)
        confidence = scores.get("confidence", 0)
        tfidf_similarity = scores.get("tfidf_similarity", 0)
        euclidean_similarity = scores.get("euclidean_similarity", 0)
        manhattan_similarity = scores.get("manhattan_similarity", 0)
        domain_similarity = scores.get("domain_similarity", 0)

        # Extract keywords for both statements
        keywords1 = extract_keywords_spacy(statement1)
        keywords2 = extract_keywords_spacy(statement2)

        # Find common keywords and calculate overlap
        common_keywords = find_common_keywords(keywords1, keywords2)
        overlap_percent = (
            min(
                100,
                int(len(common_keywords) / max(len(keywords1), len(keywords2)) * 100),
            )
            if keywords1 and keywords2
            else 0
        )

        # Create a standardized result structure
        result = {
            "basic_score": basic_score,
            "combined_score": combined_score,
            "confidence": confidence,
            "interpretation": get_interpretation(combined_score),
            "overlap_percent": overlap_percent,
            "metrics": {
                "tfidf": tfidf_similarity,
                "euclidean": euclidean_similarity,
                "manhattan": manhattan_similarity,
                "domain": domain_similarity,
            },
            "keywords": {
                "statement1": keywords1,
                "statement2": keywords2,
                "common": common_keywords,
            },
        }

        return result

    except Exception as e:
        print(f"Error in process_comparison_pair: {str(e)}")
        print(traceback.format_exc())
        return {
            "error": str(e),
            "basic_score": 0,
            "combined_score": 0,
            "confidence": 0,
            "interpretation": "error",
        }


def ensure_string(item):
    """Convert any char-like item to a proper string"""
    if isinstance(item, bytes):
        return item.decode("utf-8")
    if isinstance(item, list) and all(isinstance(x, int) for x in item):
        return "".join(chr(x) for x in item)
    return str(item)


def process_comparison_with_embeddings(statement1, statement2, embedding1, embedding2):
    """
    Process comparison using pre-computed embeddings.
    This skips the expensive embedding generation step.
    """
    import numpy as np
    from scipy import spatial
    import re
    from sklearn.feature_extraction.text import TfidfVectorizer

    # Reuse the logic from process_comparison_pair but skip embedding generation

    # Extract keywords from statements
    def extract_keywords(text):
        # Lowercase and remove special chars
        text = re.sub(r"[^\w\s]", " ", text.lower())

        # Simple word-based extraction (you can replace with your existing implementation)
        words = text.split()
        # Filter out very short words and common stop words
        stop_words = {
            "und",
            "der",
            "die",
            "das",
            "ein",
            "eine",
            "zu",
            "in",
            "ist",
            "es",
            "für",
            "von",
            "wird",
        }
        keywords = [w for w in words if len(w) > 2 and w not in stop_words]
        return keywords

    # Compute keyword overlap
    keywords1 = extract_keywords(statement1)
    keywords2 = extract_keywords(statement2)

    # Make sure keywords are strings, not lists of characters
    keywords1 = [ensure_string(k) for k in keywords1]
    keywords2 = [ensure_string(k) for k in keywords2]

    if keywords1 and keywords2:
        common_keywords = list(set(keywords1).intersection(set(keywords2)))
        # Calculate what percentage of keywords from statement2 are in statement1
        if keywords2:
            overlap_percent = int((len(common_keywords) / len(keywords2)) * 100)
        else:
            overlap_percent = 0
    else:
        common_keywords = []
        overlap_percent = 0

    # Ensure empty list for common keywords, not empty string
    if not common_keywords:
        common_keywords = []

    # Calculate various similarity metrics

    # 1. Cosine similarity using pre-computed embeddings
    cosine_sim = 1 - spatial.distance.cosine(embedding1, embedding2)
    cosine_score = int(cosine_sim * 100)  # Convert to 0-100 scale

    # 2. TF-IDF similarity
    tfidf_vectorizer = TfidfVectorizer()
    try:
        tfidf_matrix = tfidf_vectorizer.fit_transform([statement1, statement2])
        tfidf_similarity = int(
            (
                1
                - spatial.distance.cosine(
                    tfidf_matrix[0].toarray().flatten(),
                    tfidf_matrix[1].toarray().flatten(),
                )
            )
            * 100
        )
    except:
        tfidf_similarity = 0

    # 3. Euclidean similarity
    euclidean_distance = np.linalg.norm(embedding1 - embedding2)
    max_distance = 2.0  # Conservative max distance estimate
    euclidean_similarity = int((1 - min(euclidean_distance / max_distance, 1.0)) * 100)

    # 4. Manhattan similarity
    manhattan_distance = np.sum(np.abs(embedding1 - embedding2))
    max_manhattan = 10.0  # Conservative max distance for manhattan
    manhattan_similarity = int((1 - min(manhattan_distance / max_manhattan, 1.0)) * 100)

    # 5. Domain sensitivity (weighted heavily on keyword overlap)
    domain_similarity = int((cosine_score * 0.5) + (overlap_percent * 0.5))

    # Combined score calculation
    basic_score = int((cosine_score * 0.7) + (tfidf_similarity * 0.3))

    # Apply keyword overlap bonus (up to +15%)
    keyword_bonus = min(15, overlap_percent // 10 * 3)  # 3 points for each 10% overlap
    combined_score = min(100, basic_score + keyword_bonus)

    # Assess confidence in the score
    confidence = int(min(100, 50 + (cosine_score - 50) * 0.7 + overlap_percent * 0.3))

    def get_interpretation(score):
        if score >= 80:
            return "strong_match"
        elif score >= 60:
            return "moderate_match"
        elif score >= 40:
            return "weak_match"
        else:
            return "no_match"

    # Prepare result dictionary matching the format from process_comparison_pair
    result = {
        "statement1": ensure_string(
            statement1
        ),  # Explicitly include statements as strings
        "statement2": ensure_string(
            statement2
        ),  # Explicitly include statements as strings
        "basic_score": basic_score,
        "combined_score": combined_score,
        "confidence": confidence,
        "interpretation": get_interpretation(combined_score),
        "overlap_percent": overlap_percent,
        "metrics": {
            "tfidf": tfidf_similarity,
            "euclidean": euclidean_similarity,
            "manhattan": manhattan_similarity,
            "domain": domain_similarity,
        },
        "keywords": {
            "statement1": keywords1,
            "statement2": keywords2,
            "common": common_keywords,
        },
    }

    return result


def get_interpretation(score):
    """Get textual interpretation based on similarity score"""
    if score < 10:
        return "completely different"
    elif score < 25:
        return "mostly different"
    elif score < 50:
        return "somewhat similar"
    elif score < 75:
        return "very similar"
    else:
        return "nearly identical"


def find_common_keywords(keywords1, keywords2):
    """Find exact common keywords between two lists."""
    # Convert to lowercase for case-insensitive comparison
    kw1_lower = [k.lower() for k in keywords1]
    kw2_lower = [k.lower() for k in keywords2]

    # Find common keywords (preserving case from the first list)
    common = []
    for i, kw in enumerate(kw1_lower):
        if kw in kw2_lower:
            common.append(keywords1[i])

    return common


def _get_model():
    """Lazy loader for the model - only loads when actually needed"""
    global _model, _initialized

    if _model is None:
        print("Loading sentence transformer model (first time only)...")
        # Set environment variable to disable symlink warnings
        os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"
        _model = SentenceTransformer("paraphrase-multilingual-MiniLM-L12-v2")
        _initialized = True

    return _model


def get_similarity_score(sentence1, sentence2):
    model = _get_model()
    embeddings = model.encode([sentence1, sentence2])

    # Get multiple metrics
    transformer_score = cosine_similarity([embeddings[0]], [embeddings[1]])[0][0]

    # TF-IDF for lexical similarity - strongest indicator of similarity
    from sklearn.feature_extraction.text import TfidfVectorizer

    vectorizer = TfidfVectorizer()
    try:
        tfidf_matrix = vectorizer.fit_transform([sentence1, sentence2])
        tfidf_score = cosine_similarity(tfidf_matrix[0], tfidf_matrix[1])[0][0]
    except:
        tfidf_score = 0

    # Emphasize TF-IDF even more in the weighting
    weighted_score = (transformer_score * 0.3) + (tfidf_score * 0.7)

    # Even stronger normalization for better discrimination
    if weighted_score < 0.3:  # Very different
        normalized = int(weighted_score * 40)  # Max 12%
    elif weighted_score < 0.5:  # Somewhat different
        normalized = int(12 + (weighted_score - 0.3) * 140)  # 12-40%
    elif weighted_score < 0.7:  # Somewhat similar
        normalized = int(40 + (weighted_score - 0.5) * 150)  # 40-70%
    else:  # Very similar
        normalized = int(70 + (weighted_score - 0.7) * 100)  # 70-100%

    return normalized


# Simple word tokenizer for German text
def simple_tokenize(text):
    # Handle bytes object by decoding to string first
    if isinstance(text, bytes):
        text = text.decode("utf-8")

    # Remove punctuation and split by whitespace
    words = re.findall(r"\b\w+\b", text.lower())
    return words


def extract_semantic_keywords(text, language="de"):
    """Extract keywords with semantic information"""
    try:
        # Get standard keywords using spaCy
        keywords = extract_keywords_spacy(text, language)

        # Get word embeddings for keywords
        model = _get_model()
        keyword_embeddings = {}

        # Generate embeddings for each keyword
        for keyword in keywords:
            # Store embedding vector for each keyword
            keyword_embeddings[keyword] = model.encode([keyword])[0]

        return {"keywords": keywords, "embeddings": keyword_embeddings}
    except Exception as e:
        print(f"Error in semantic keyword extraction: {str(e)}")
        return {"keywords": [], "embeddings": {}}


def find_semantic_keyword_overlap(keywords1, embeddings1, keywords2, embeddings2):
    """Find semantic overlap between keyword sets with higher threshold"""
    overlap_pairs = []

    # Compare each keyword from set 1 with each from set 2
    for k1 in keywords1:
        if len(k1) < 3:  # Skip very short keywords
            continue

        for k2 in keywords2:
            if len(k2) < 3:  # Skip very short keywords
                continue

            # Skip if the keywords are common words
            if k1.lower() in [
                "und",
                "mit",
                "the",
                "des",
                "vom",
                "ist",
            ] or k2.lower() in ["und", "mit", "the", "des", "vom", "ist"]:
                continue

            # Calculate semantic similarity
            sim = cosine_similarity([embeddings1[k1]], [embeddings2[k2]])[0][0]

            # Higher threshold (0.85 instead of 0.7)
            if sim > 0.85:
                overlap_pairs.append((k1, k2, sim))

    # Sort by similarity
    overlap_pairs.sort(key=lambda x: x[2], reverse=True)

    return overlap_pairs


def get_alternative_similarity_scores(sentence1, sentence2):
    """Compare texts using multiple methods and return all scores"""
    import numpy as np

    try:
        # Get model and embeddings
        model = _get_model()
        embeddings = model.encode([sentence1, sentence2])

        # 1. Standard similarity (consistent with get_similarity_score)
        standard_similarity = get_similarity_score(sentence1, sentence2)

        # 2. Cosine similarity of raw embeddings
        cosine_score = cosine_similarity([embeddings[0]], [embeddings[1]])[0][0]

        # 3. Euclidean distance (converted to similarity)
        euclidean_dist = np.linalg.norm(embeddings[0] - embeddings[1])
        euclidean_sim = int(100 / (1 + euclidean_dist))  # Normalize to 0-100

        # 4. Manhattan distance (converted to similarity)
        manhattan_dist = np.sum(np.abs(embeddings[0] - embeddings[1]))
        manhattan_sim = int(100 / (1 + manhattan_dist * 0.1))  # Normalize

        # 5. TF-IDF based similarity
        from sklearn.feature_extraction.text import TfidfVectorizer

        vectorizer = TfidfVectorizer()
        try:
            tfidf_matrix = vectorizer.fit_transform([sentence1, sentence2])
            tfidf_sim = cosine_similarity(tfidf_matrix[0], tfidf_matrix[1])[0][0]
            tfidf_score = int(tfidf_sim * 100)  # Convert to percentage
        except:
            tfidf_score = 0

        # 6. Domain-specific similarity based on content words
        domain_score = get_domain_similarity(sentence1, sentence2)

        # 7. Combined score (weighted average of the most reliable metrics)
        combined_score = int(
            0.5 * standard_similarity  # Base similarity (most reliable)
            + 0.3 * tfidf_score  # Lexical overlap
            + 0.1 * domain_score  # Decrease domain influence
            + 0.1 * euclidean_sim  # Add distance metric
        )

        # Calculate confidence in the similarity assessment
        confidence = calculate_confidence(
            {
                "standard_similarity": standard_similarity,
                "euclidean_similarity": euclidean_sim,
                "manhattan_similarity": manhattan_sim,
                "tfidf_similarity": tfidf_score,
            }
        )

        # Return all scores as a dictionary
        return {
            "standard_similarity": standard_similarity,
            "euclidean_similarity": euclidean_sim,
            "manhattan_similarity": manhattan_sim,
            "tfidf_similarity": tfidf_score,
            "domain_similarity": domain_score,
            "combined_score": combined_score,
            "confidence": confidence,
        }

    except Exception as e:
        print(f"Error in alternative similarity calculation: {str(e)}")
        # Provide fallback scores
        return {
            "standard_similarity": 0,
            "euclidean_similarity": 0,
            "manhattan_similarity": 0,
            "tfidf_similarity": 0,
            "domain_similarity": 0,
            "combined_score": 0,
            "error": str(e),
        }


def get_domain_similarity(text1, text2):
    """Calculate domain similarity based on content words"""
    import numpy as np

    try:
        # Try to use spaCy for better extraction of content words
        try:
            import spacy

            # Load German language model
            try:
                nlp = spacy.load("de_core_news_sm")
            except:
                # Fall back to English model if German isn't available
                nlp = spacy.load("en_core_web_sm")

            # Process both texts
            doc1 = nlp(text1[:5000])  # Limit length for performance
            doc2 = nlp(text2[:5000])

            # Get content-bearing words (nouns, verbs, proper nouns)
            content_words1 = [
                token.lemma_
                for token in doc1
                if token.pos_ in ("NOUN", "PROPN", "VERB")
                and not token.is_stop
                and len(token.text) > 2
            ]

            content_words2 = [
                token.lemma_
                for token in doc2
                if token.pos_ in ("NOUN", "PROPN", "VERB")
                and not token.is_stop
                and len(token.text) > 2
            ]

        except:
            # Fallback to simple tokenization if spaCy fails
            content_words1 = [word for word in simple_tokenize(text1) if len(word) > 3]
            content_words2 = [word for word in simple_tokenize(text2) if len(word) > 3]

        # Get unique words
        unique_words1 = list(set(content_words1))[:20]  # Limit to 20 words max
        unique_words2 = list(set(content_words2))[:20]

        # Guard clause for empty word lists
        if not unique_words1 or not unique_words2:
            return 0

        # Get model and calculate embeddings
        model = _get_model()

        # Average embeddings for all content words to get domain vectors
        embeddings1 = model.encode(unique_words1)
        embeddings2 = model.encode(unique_words2)

        # Instead of simple averaging, weight by word importance
        # This will prioritize domain-specific terminology
        word_importance1 = [
            len(word) for word in unique_words1
        ]  # Longer words often more specific
        word_importance2 = [len(word) for word in unique_words2]

        # Weighted average
        domain_vector1 = np.average(embeddings1, axis=0, weights=word_importance1)
        domain_vector2 = np.average(embeddings2, axis=0, weights=word_importance2)

        # Calculate similarity between domain vectors
        domain_sim = cosine_similarity([domain_vector1], [domain_vector2])[0][0]

        # Stronger normalization for better discrimination
        domain_score = (
            int((domain_sim - 0.7) * 333) if domain_sim > 0.7 else int(domain_sim * 70)
        )

        # Add entropy-based adjustment: higher penalty for common domains
        # Insurance/technical domains are common in your corpus, should be weighted less
        insurance_terms = {"schaden", "objekt", "kosten", "daten", "technisch"}
        tech_terms = {"module", "state", "input", "output"}

        words1_set = set([w.lower() for w in unique_words1])
        words2_set = set([w.lower() for w in unique_words2])

        insurance_overlap1 = len(words1_set.intersection(insurance_terms)) / len(
            insurance_terms
        )
        insurance_overlap2 = len(words2_set.intersection(insurance_terms)) / len(
            insurance_terms
        )
        tech_overlap1 = len(words1_set.intersection(tech_terms)) / len(tech_terms)
        tech_overlap2 = len(words2_set.intersection(tech_terms)) / len(tech_terms)

        # If both texts are from the same common domain, reduce domain similarity
        if (insurance_overlap1 > 0.2 and insurance_overlap2 > 0.2) or (
            tech_overlap1 > 0.2 and tech_overlap2 > 0.2
        ):
            domain_score = int(domain_score * 0.7)

        return max(0, min(100, domain_score))

    except Exception as e:
        print(f"Error in domain similarity: {str(e)}")
        return 0


def calculate_confidence(scores):
    """Calculate confidence level in similarity assessment"""
    # Consistency between different metrics indicates higher confidence
    standard = scores["standard_similarity"]
    tfidf = scores["tfidf_similarity"]

    # Agreement between metrics (inverse of variance)
    metrics = [
        scores["standard_similarity"],
        scores["tfidf_similarity"],
        scores["euclidean_similarity"],
        scores["manhattan_similarity"],
    ]
    variance = np.var(metrics)
    agreement = 100 / (1 + variance)

    # Extremity factor (very low or very high scores tend to be more reliable)
    extremity = max(standard, 100 - standard) / 50  # 0.0-2.0 factor

    # Combine these factors
    confidence = int((agreement * 0.7 * extremity) + (100 - abs(standard - tfidf)))

    return min(100, max(0, confidence))


def extract_keywords(text):
    """Enhanced simple keyword extraction with stopword handling"""
    try:
        # Handle bytes object by decoding
        if isinstance(text, bytes):
            text = text.decode("utf-8")

        # Simple keyword extraction using basic tokenization
        words = simple_tokenize(text)

        # Common German and English stopwords to filter out
        stopwords = {
            "und",
            "mit",
            "der",
            "die",
            "das",
            "ein",
            "eine",
            "the",
            "and",
            "ist",
            "zu",
            "von",
            "für",
            "des",
            "vom",
            "im",
            "of",
            "to",
            "in",
        }

        # Filter out stopwords and short words
        filtered_words = [
            word for word in words if word not in stopwords and len(word) > 2
        ]

        # Count word frequencies
        word_counts = Counter(filtered_words)

        # Get most common words
        keywords = [word for word, count in word_counts.most_common(15)]

        return keywords[:10]  # Return top 10 keywords
    except Exception as e:
        print(f"Error in extract_keywords: {str(e)}")
        return []


def extract_keywords_spacy(text, language="de"):
    """Extract keywords using spaCy without SIGALRM (Windows compatible)"""
    import spacy
    import threading
    import time

    try:
        # Convert bytes to string if needed
        if isinstance(text, bytes):
            text = text.decode("utf-8")

        # Load appropriate language model
        if language == "de":
            try:
                nlp = spacy.load("de_core_news_sm")
            except:
                nlp = spacy.load("en_core_web_sm")
        else:
            nlp = spacy.load("en_core_web_sm")

        # Process with spaCy - limit text length
        doc = nlp(text[:5000])

        # Get important entities
        entities = [ent.text for ent in doc.ents]

        # Get noun chunks (noun phrases)
        noun_chunks = [chunk.text for chunk in doc.noun_chunks]

        # Get important words (filter out stopwords)
        important_words = [
            token.lemma_
            for token in doc
            if not token.is_stop  # This is critical to filter "und", "mit", etc.
            and not token.is_punct
            and len(token.text) > 2  # Additional length filter
            and token.pos_ in ("NOUN", "VERB", "ADJ", "PROPN")
        ]

        # Combine, deduplicate and sort by importance
        # After extracting entities, noun chunks and important words:

        # Filter out low-quality keywords
        # 1. Ensure noun chunks are properly formed
        filtered_chunks = []
        for chunk in noun_chunks:
            # Keep chunks with 1-3 words, not ending with stopwords
            words = chunk.split()
            if 1 <= len(words) <= 3:
                filtered_chunks.append(chunk)

        # 2. Prioritize more informative words
        # Words that are longer tend to be more specific/informative
        important_words = sorted(important_words, key=len, reverse=True)[:15]

        # Combine, deduplicate and sort by importance
        all_keywords = entities + filtered_chunks + important_words

        # Ensure all keywords are proper strings
        keywords = [ensure_string(k.lower()) for k in all_keywords]

        # Return deduplicated list (up to 10)
        return list(dict.fromkeys(keywords))[:10]
    except Exception as e:
        print(f"Error in extract_keywords_spacy: {str(e)}")
        return extract_keywords(text)  # Fall back to simple method


def compare_statements(statement1, statement2):
    try:
        # Get similarity score
        score = get_similarity_score(statement1, statement2)

        # Get alternative scores for additional metrics
        alt_scores = get_alternative_similarity_scores(statement1, statement2)

        # Detect language for each statement
        lang1 = detect_language(statement1)
        lang2 = detect_language(statement2)

        # Get keywords WITH embeddings for both statements
        keywords_data1 = extract_semantic_keywords(statement1, lang1)
        keywords_data2 = extract_semantic_keywords(statement2, lang2)

        keywords1 = keywords_data1["keywords"]
        keywords2 = keywords_data2["keywords"]

        # Find semantic keyword overlap
        semantic_matches = find_semantic_keyword_overlap(
            keywords1,
            keywords_data1["embeddings"],
            keywords2,
            keywords_data2["embeddings"],
        )

        # Format the semantic matches for display
        common_keywords = [
            f"{k1} ≈ {k2} ({score:.2f})" for k1, k2, score in semantic_matches
        ]

        # Calculate semantic overlap percentage
        overlap_percent = min(
            100, int(len(semantic_matches) / max(len(keywords1), len(keywords2)) * 100)
        )

        # Build result dictionary with additional metrics
        result = {
            "similarity_score": score,
            "keywords1": keywords1,
            "keywords2": keywords2,
            "keyword_overlap_percent": overlap_percent,
            "common_keywords": common_keywords,
            "combined_score": alt_scores.get("combined_score", score),
            "confidence": alt_scores.get("confidence", 80),
        }

        # Add interpretation based on combined_score
        combined = result["combined_score"]
        if combined < 10:
            result["interpretation"] = "completely different"
        elif combined < 25:
            result["interpretation"] = "mostly different"
        elif combined < 50:
            result["interpretation"] = "somewhat similar"
        elif combined < 75:
            result["interpretation"] = "very similar"
        else:
            result["interpretation"] = "nearly identical"

        # Convert to list of tuples for ErlPort compatibility
        return [(str(key), value) for key, value in result.items()]
    except Exception as e:
        print(f"Error in compare_statements: {str(e)}")
        return [("error", str(e))]


def detect_language(text):
    """Detect language of text"""
    try:
        from langdetect import detect

        return detect(text)
    except:
        # Default to German if detection fails or langdetect not installed
        return "de"


def test_connection():
    """
    Simple function to test if the connection to Python is working.
    """
    try:
        return "ok"
    except Exception as e:
        return f"error: {str(e)}"


def is_model_loaded():
    """Check if model has been loaded yet"""
    global _initialized
    return "loaded" if _initialized else "not loaded"


def reload_module(module_name=None):
    """
    Safe reload of a module without re-initializing expensive resources
    Only reloads code, not global variables/models
    """
    if module_name is None:
        # Default to this module
        module_name = __name__

    try:
        import importlib

        # Store important globals we want to keep
        global _model, _initialized
        saved_model = _model
        saved_initialized = _initialized

        # Reload the module
        if module_name in sys.modules:
            module = importlib.reload(sys.modules[module_name])

        # Restore important globals
        sys.modules[module_name]._model = saved_model
        sys.modules[module_name]._initialized = saved_initialized

        return "Module reloaded successfully while preserving model state"
    except Exception as e:
        return f"Error during reload: {str(e)}"


def dispatch(module_name, func_name, args):
    """
    Generic dispatcher: import module_name, call func_name with args
    """
    module = __import__(module_name)
    func = getattr(module, func_name)
    return func(*args)
