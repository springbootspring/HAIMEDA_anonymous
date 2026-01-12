import gc
import os
import subprocess
import sys
import time
import traceback

try:
    import torch

    HAS_TORCH = True
except ImportError:
    HAS_TORCH = False

# Global model instance to avoid duplicate loading
_model = None

# Estimated VRAM usage per worker in MB
VRAM_PER_WORKER = 200  # 3GB per worker as a conservative estimate


def get_vram_info():
    """Get detailed VRAM information for all GPUs"""
    # Skip GPU detection on macOS
    if sys.platform == "darwin":
        return {"available": False}

    if not HAS_TORCH or not torch.cuda.is_available():
        return {"available": False}

    result = {"available": True, "devices": []}

    for i in range(torch.cuda.device_count()):
        try:
            # Try using nvidia-smi for accurate info
            try:
                nvidia_output = (
                    subprocess.run(
                        [
                            "nvidia-smi",
                            f"--query-gpu=memory.total,memory.used,memory.free",
                            "--format=csv,noheader,nounits",
                            "-i",
                            str(i),
                        ],
                        check=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=5,
                    )
                    .stdout.strip()
                    .split(",")
                )

                if len(nvidia_output) >= 3:
                    total_mb = int(nvidia_output[0].strip())
                    used_mb = int(nvidia_output[1].strip())
                    free_mb = int(nvidia_output[2].strip())

                    result["devices"].append(
                        {
                            "id": i,
                            "name": torch.cuda.get_device_name(i),
                            "total_mb": total_mb,
                            "used_mb": used_mb,
                            "free_mb": free_mb,
                        }
                    )
                    continue  # Skip the fallback if nvidia-smi worked
            except:
                pass  # Fall back to torch.cuda methods

            # Fallback to torch.cuda (less accurate)
            device_props = torch.cuda.get_device_properties(i)
            total_mb = device_props.total_memory / (1024**2)
            allocated_mb = torch.cuda.memory_allocated(i) / (1024**2)
            reserved_mb = torch.cuda.memory_reserved(i) / (1024**2)
            free_mb = total_mb - reserved_mb

            result["devices"].append(
                {
                    "id": i,
                    "name": torch.cuda.get_device_name(i),
                    "total_mb": int(total_mb),
                    "used_mb": int(allocated_mb),
                    "free_mb": int(free_mb),
                }
            )

        except Exception as e:
            print(f"Error getting VRAM for GPU {i}: {e}")
            result["devices"].append({"id": i, "error": str(e)})

    # Calculate total available VRAM across all GPUs
    total_free_vram = sum(device.get("free_mb", 0) for device in result["devices"])
    result["total_free_mb"] = total_free_vram

    return result


def get_optimal_worker_count():
    """Calculate optimal worker count based on available VRAM and system resources"""
    # macOS fallback to CPU only
    if sys.platform == "darwin":
        cpu_cores = os.cpu_count() or 4
        worker_count = max(1, cpu_cores - 1)
        print(f"macOS detected; using {worker_count} CPU workers")
        return worker_count

    if not HAS_TORCH:
        # Default to CPU-based calculation if torch not available
        cpu_cores = os.cpu_count() or 4
        return max(1, cpu_cores - 1)

    try:
        # Check if CUDA is available for GPU processing
        if torch.cuda.is_available():
            # Get VRAM information
            vram_info = get_vram_info()
            total_free_vram = vram_info.get("total_free_mb", 0)

            if total_free_vram > 0:
                print(f"Total free VRAM across all GPUs: {total_free_vram} MB")

                # Reserve 20% VRAM for overhead and system
                usable_vram = total_free_vram * 0.8

                # Calculate workers based on VRAM per worker (3GB default)
                vram_workers = max(1, int(usable_vram / VRAM_PER_WORKER))

                # Get CPU core count for additional constraint
                # (we still need CPU threads to manage the GPU workers)
                cpu_cores = os.cpu_count() or 4
                cpu_workers = max(1, cpu_cores - 1)

                # Use the lower of the two limits
                worker_count = min(vram_workers, cpu_workers)

                print(
                    f"VRAM allows for {vram_workers} workers, CPU allows for {cpu_workers} workers"
                )
                print(f"Using {worker_count} workers based on available resources")

                # Cap at a reasonable maximum
                return min(worker_count, 16)
            else:
                # Fallback to CPU if VRAM info not available
                cpu_cores = os.cpu_count() or 4
                worker_count = max(1, cpu_cores - 1)
                print(f"Using {worker_count} CPU workers (no VRAM info available)")
                return worker_count
        else:
            # No CUDA, use CPU-based calculation
            cpu_cores = os.cpu_count() or 4
            worker_count = max(1, cpu_cores - 1)
            print(f"CUDA not available. Using {worker_count} CPU workers")
            return worker_count
    except Exception as e:
        # Safe fallback
        print(f"Error calculating optimal worker count: {e}")
        return 2


def get_model():
    """Get or create singleton model instance"""
    global _model
    if _model is None:
        try:
            # Defer import to avoid loading model until needed
            from sentence_transformers import SentenceTransformer

            _model = SentenceTransformer("paraphrase-multilingual-MiniLM-L12-v2")
            print("Model loaded successfully")
        except Exception as e:
            print(f"Error loading model: {str(e)}")
            return None
    return _model


def ensure_string(item):
    """Ensure an item is a proper string, not a list representation"""
    if isinstance(item, list):
        try:
            # Try to convert list of integers to string
            if all(isinstance(x, int) for x in item):
                return "".join(chr(x) for x in item)
        except:
            pass

        # If that fails, convert to regular string
        return str(item)
    return str(item)


def process_batch(statement_pairs):
    """
    Main entry point for ErlPort to call from Elixir

    Args:
        statement_pairs: List of (statement1, statement2) tuples to compare

    Returns:
        List of comparison results with statement1, statement2 and result
    """
    # Convert parameters from Elixir format
    decoded_pairs = []
    for pair in statement_pairs:
        stmt1 = pair[0].decode("utf-8") if isinstance(pair[0], bytes) else pair[0]
        stmt2 = pair[1].decode("utf-8") if isinstance(pair[1], bytes) else pair[1]
        decoded_pairs.append((stmt1, stmt2))

    print(f"Processing batch of {len(decoded_pairs)} statement pairs")

    try:
        # Try parallel processing first
        if HAS_TORCH:
            try:
                # Calculate optimal worker count
                process_count = get_optimal_worker_count()
                print(f"Attempting parallel processing with {process_count} workers")
                results = process_batch_parallel(decoded_pairs, process_count)
                print("Parallel processing completed successfully")
            except Exception as e:
                print(f"Parallel processing failed: {str(e)}")
                print(traceback.format_exc())
                print("Falling back to sequential processing")
        else:
            # If torch isn't available, use sequential processing
            print("Torch not available, using sequential processing")
    except Exception as e:
        print(f"Error during batch processing: {str(e)}")
        print(traceback.format_exc())
        # Create empty results with error messages
        results = [
            {
                "error": str(e),
                "basic_score": 0,
                "combined_score": 0,
                "confidence": 0,
                "interpretation": "error",
                "overlap_percent": 0,
                "tfidf_similarity": 0,
                "euclidean_similarity": 0,
                "manhattan_similarity": 0,
                "domain_similarity": 0,
                "keywords1": [],
                "keywords2": [],
                "common_keywords": [],
                "metrics": {"tfidf": 0, "euclidean": 0, "manhattan": 0, "domain": 0},
            }
            for _ in decoded_pairs
        ]

    # Format results for Elixir compatibility
    formatted_results = []
    for i, (stmt1, stmt2) in enumerate(decoded_pairs):
        # Ensure we have a valid result or use a default structure
        result = (
            results[i]
            if i < len(results) and results[i] is not None
            else {
                "error": "No result produced",
                "basic_score": 0,
                "combined_score": 0,
                "confidence": 0,
                "interpretation": "error",
                "overlap_percent": 0,
                "metrics": {"tfidf": 0, "euclidean": 0, "manhattan": 0, "domain": 0},
                "keywords": {"statement1": [], "statement2": [], "common": []},
            }
        )

        # Convert any keywords that might be character arrays to proper strings
        keywords1 = (
            result.get("keywords1", [])
            if "keywords1" in result
            else result.get("keywords", {}).get("statement1", [])
        )
        keywords2 = (
            result.get("keywords2", [])
            if "keywords2" in result
            else result.get("keywords", {}).get("statement2", [])
        )
        common_keywords = (
            result.get("common_keywords", [])
            if "common_keywords" in result
            else result.get("keywords", {}).get("common", [])
        )

        # print(f"keywords1: {keywords1}")
        # print(f"keywords2: {keywords2}")
        # print(f"common_keywords: {common_keywords}")

        # Ensure all keywords are proper strings to avoid charlist issues in Elixir
        keywords1 = [ensure_string(k) for k in keywords1]
        keywords2 = [ensure_string(k) for k in keywords2]
        common_keywords = [ensure_string(k) for k in common_keywords]

        # Ensure statements are proper strings
        stmt1_str = ensure_string(stmt1)
        stmt2_str = ensure_string(stmt2)

        # print(f"stmt1_str: {stmt1_str}")
        # print(f"stmt2_str: {stmt2_str}")

        formatted_results.append(
            {
                "statement1": stmt1_str,
                "statement2": stmt2_str,
                "basic_score": result.get("basic_score", 0),
                "combined_score": result.get("combined_score", 0),
                "confidence": result.get("confidence", 0),
                "interpretation": result.get("interpretation", "unknown"),
                "overlap_percent": result.get("overlap_percent", 0),
                "tfidf_similarity": (
                    result.get("tfidf_similarity", 0)
                    if "tfidf_similarity" in result
                    else result.get("metrics", {}).get("tfidf", 0)
                ),
                "euclidean_similarity": (
                    result.get("euclidean_similarity", 0)
                    if "euclidean_similarity" in result
                    else result.get("metrics", {}).get("euclidean", 0)
                ),
                "manhattan_similarity": (
                    result.get("manhattan_similarity", 0)
                    if "manhattan_similarity" in result
                    else result.get("metrics", {}).get("manhattan", 0)
                ),
                "domain_similarity": (
                    result.get("domain_similarity", 0)
                    if "domain_similarity" in result
                    else result.get("metrics", {}).get("domain", 0)
                ),
                "keywords1": keywords1,
                "keywords2": keywords2,
                "common_keywords": common_keywords,
            }
        )

    # Clean up to release memory
    gc.collect()
    if HAS_TORCH and torch.cuda.is_available():
        torch.cuda.empty_cache()

    return formatted_results


def process_batch_sequential(statement_pairs):
    """Process statement pairs sequentially to avoid memory issues"""
    print("Starting sequential processing...")
    import statement_scoring

    results = []
    for i, (stmt1, stmt2) in enumerate(statement_pairs):
        if i % 10 == 0:  # Log progress every 10 items
            print(f"Processing pair {i+1}/{len(statement_pairs)}")

        try:
            # Process single comparison
            result = statement_scoring.process_comparison_pair(stmt1, stmt2)
            results.append(result)

            # Periodically clear memory
            if i % 20 == 19:  # Every 20 items
                gc.collect()
                if HAS_TORCH and torch.cuda.is_available():
                    torch.cuda.empty_cache()
        except Exception as e:
            print(f"Error processing pair {i+1}: {str(e)}")
            # Add a placeholder result with error information
            results.append(
                {
                    "error": str(e),
                    "basic_score": 0,
                    "combined_score": 0,
                    "confidence": 0,
                    "interpretation": "error",
                }
            )

    print(f"Sequential processing complete. Processed {len(results)} pairs")
    return results


def get_vram_usage():
    """Get current VRAM usage information"""
    return get_vram_info()


def release_resources():
    """Release memory used by loaded models and clear CUDA cache"""
    global _model

    # Clear model reference
    if _model is not None:
        del _model
        _model = None

    # Force garbage collection
    gc.collect()

    # Clear CUDA cache if available
    if HAS_TORCH and torch.cuda.is_available():
        try:
            torch.cuda.empty_cache()
            print("Successfully cleared CUDA cache")

            # Report remaining memory usage
            vram_info = get_vram_usage()
            for device in vram_info.get("devices", []):
                if "free_mb" in device and "total_mb" in device:
                    print(
                        f"GPU {device['id']}: {device['free_mb']} MB free out of {device['total_mb']} MB"
                    )
        except Exception as e:
            print(f"Error clearing CUDA cache: {str(e)}")

    return "Resources released"


def test_connection():
    """Required for the gateway API to verify connection"""
    return "ok"


def process_batch_parallel(statement_pairs, num_workers=None):
    """Process using ThreadPoolExecutor with shared pre-computed embeddings"""
    import concurrent.futures
    import statement_scoring
    import time
    from scipy import spatial
    import numpy as np

    total_pairs = len(statement_pairs)
    print(
        f"Starting optimized parallel processing of {total_pairs} pairs with {num_workers} workers"
    )
    start_time = time.time()

    # First, extract all unique statements to process
    all_statements = []
    statement_set = set()
    statement_to_index = {}

    print("Extracting unique statements...")
    for s1, s2 in statement_pairs:
        if s1 not in statement_set:
            statement_to_index[s1] = len(all_statements)
            all_statements.append(s1)
            statement_set.add(s1)
        if s2 not in statement_set:
            statement_to_index[s2] = len(all_statements)
            all_statements.append(s2)
            statement_set.add(s2)

    unique_count = len(all_statements)
    print(f"Found {unique_count} unique statements out of {total_pairs*2} total")

    # Load model ONCE
    print("Loading sentence transformer model (one time for all comparisons)...")
    model = get_model()

    # Generate all embeddings in a single batch operation
    print(f"Pre-computing embeddings for all {unique_count} unique statements...")
    embedding_start = time.time()
    all_embeddings = model.encode(all_statements, show_progress_bar=True)
    embedding_time = time.time() - embedding_start
    print(
        f"Generated all embeddings in {embedding_time:.2f} seconds ({unique_count/embedding_time:.2f} statements/sec)"
    )

    # Function to process a comparison with pre-computed embeddings
    def process_with_embeddings(idx, s1, s2):
        try:
            # Get pre-computed embeddings from the array
            emb1_idx = statement_to_index[s1]
            emb2_idx = statement_to_index[s2]
            embedding1 = all_embeddings[emb1_idx]
            embedding2 = all_embeddings[emb2_idx]

            # Use statement_scoring's core comparison logic but skip embedding generation
            result = statement_scoring.process_comparison_with_embeddings(
                s1, s2, embedding1, embedding2
            )

            # Ensure all keywords are strings, not character arrays
            if "keywords" in result and isinstance(result["keywords"], dict):
                for key in ["statement1", "statement2", "common"]:
                    if key in result["keywords"]:
                        result["keywords"][key] = [
                            ensure_string(k) for k in result["keywords"][key]
                        ]

            # Also handle the flat structure if present
            for key in ["keywords1", "keywords2", "common_keywords"]:
                if key in result:
                    result[key] = [ensure_string(k) for k in result[key]]

            # Ensure common_keywords is always a list, not an empty string
            if "common_keywords" in result and result["common_keywords"] == "":
                result["common_keywords"] = []
            if (
                "keywords" in result
                and "common" in result["keywords"]
                and result["keywords"]["common"] == ""
            ):
                result["keywords"]["common"] = []

            return result

        except Exception as e:
            print(f"Error processing pair {idx}: {str(e)}")
            # Return a complete default object with all required fields
            return {
                "error": str(e),
                "basic_score": 0,
                "combined_score": 0,
                "confidence": 0,
                "interpretation": "error",
                "overlap_percent": 0,
                "tfidf_similarity": 0,
                "euclidean_similarity": 0,
                "manhattan_similarity": 0,
                "domain_similarity": 0,
                "keywords1": [],
                "keywords2": [],
                "common_keywords": [],
                "metrics": {"tfidf": 0, "euclidean": 0, "manhattan": 0, "domain": 0},
            }

    completed = 0

    # Create thread pool
    with concurrent.futures.ThreadPoolExecutor(max_workers=num_workers) as executor:
        # Submit all pairs to thread pool with pre-computed embeddings
        futures = {
            executor.submit(process_with_embeddings, i, s1, s2): i
            for i, (s1, s2) in enumerate(statement_pairs)
        }

        # Collect results as they complete
        results = [None] * len(statement_pairs)
        for future in concurrent.futures.as_completed(futures):
            idx = futures[future]
            try:
                result = future.result()
                # Store original statements with the result to ensure proper pairing
                result["statement1"] = statement_pairs[idx][0]
                result["statement2"] = statement_pairs[idx][1]
                results[idx] = result
                completed += 1

                # Print progress every 5 completions or at specific percentages
                if completed == 1 or completed % 5 == 0 or completed == total_pairs:
                    elapsed = time.time() - start_time
                    rate = completed / elapsed if elapsed > 0 else 0
                    print(
                        f"Progress: {completed}/{total_pairs} pairs completed "
                        f"({completed/total_pairs*100:.1f}%) - "
                        f"{rate:.2f} pairs/sec"
                    )
            except Exception as e:
                print(f"Error processing pair {idx}: {str(e)}")
                # Include original statements in error result
                results[idx] = {
                    "error": str(e),
                    "statement1": statement_pairs[idx][0],
                    "statement2": statement_pairs[idx][1],
                    "basic_score": 0,
                    "combined_score": 0,
                    "confidence": 0,
                }

    total_time = time.time() - start_time
    print(f"Parallel processing completed in {total_time:.2f} seconds")
    print(f"Average processing speed: {total_pairs/total_time:.2f} pairs/second")

    return results


def worker_batch_process(worker_id, batch, result_queue):
    """Process a batch of statement pairs in a worker process"""
    print(f"Worker {worker_id} starting with {len(batch)} pairs")

    try:
        # Import here to avoid module-level import in multiprocessing
        import statement_scoring

        results = []
        for i, (stmt1, stmt2) in enumerate(batch):
            try:
                # Process each pair - store original order for sorting later
                result = statement_scoring.process_comparison_pair(stmt1, stmt2)
                result["original_index"] = worker_id * 1000 + i
                results.append(result)

                if i % 5 == 0 and i > 0:
                    print(f"Worker {worker_id} processed {i}/{len(batch)} pairs")
            except Exception as e:
                print(f"Worker {worker_id} error processing pair {i}: {str(e)}")
                results.append(
                    {
                        "error": str(e),
                        "basic_score": 0,
                        "combined_score": 0,
                        "confidence": 0,
                        "original_index": worker_id * 1000 + i,
                    }
                )

            # Periodically free memory
            if i % 5 == 4:
                gc.collect()
                if HAS_TORCH and torch.cuda.is_available():
                    torch.cuda.empty_cache()

        # Send all results back at once
        print(f"Worker {worker_id} putting {len(results)} results in queue")
        result_queue.put(results)
        print(f"Worker {worker_id} completed successfully")
    except Exception as e:
        print(f"Worker {worker_id} failed with exception: {str(e)}")
        print(traceback.format_exc())
        # Put an empty result list to prevent hanging
        result_queue.put([])
