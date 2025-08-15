"""
System: backend
Module: api.orchestrator.utils
Purpose: Utility functions for the orchestrator workflow including song generation, 
         download, review, and intelligent retry logic.
"""

import os
import shutil
import asyncio
import traceback
from typing import Dict, Any, List, Tuple


async def execute_song_workflow(
    book_name: str,
    chapter: int,
    verse_range: str,
    style: str,
    title: str,
    song_structure_id: int = None
) -> Dict[str, Any]:
    """
    🎼 CORE ORCHESTRATOR WORKFLOW
    
    Executes the complete song generation and review process with intelligent retry logic.
    
    WORKFLOW STEPS:
    1. Generate 2 songs on Suno.com (single generation creates 2 variants)
    2. Wait for Suno processing (3 minutes) 
    3. Download both songs using negative indexing (-1, -2)
    4. AI review each song for quality
    5. Handle verdicts:
       - "continue": Move to backend/songs/final_review  
       - "re-roll": Delete and retry generation
    6. Auto-retry up to 3 times if needed
    7. Fallback: Move final attempt songs to final_review regardless
    
    Args:
        book_name (str): Bible book name
        chapter (int): Chapter number  
        verse_range (str): Verse range (e.g., "1-5")
        style (str): Musical style/genre
        title (str): Song title
        song_structure_id (int, optional): Song structure ID for review
        
    Returns:
        Dict[str, Any]: Comprehensive workflow results and statistics
    """
    print(f"🎼 [WORKFLOW] Starting orchestrated workflow for: {book_name} {chapter}:{verse_range}")
    
    # Use verification function to ensure we have the correct final destination
    final_dir = verify_final_destination_folder()
    temp_dir = "backend/songs/temp"
    
    # Ensure required directories exist
    os.makedirs(temp_dir, exist_ok=True)
    os.makedirs(final_dir, exist_ok=True)
    
    print(f"🎼 [WORKFLOW] ✅ VERIFIED: Final approved songs will be moved to: {final_dir}")
    print(f"🎼 [WORKFLOW] ✅ VERIFIED: Temporary downloads will be stored in: {temp_dir}")
    
    workflow_details = {
        "attempts": [],
        "total_songs_generated": 0,
        "total_songs_reviewed": 0, 
        "songs_kept": 0,
        "songs_deleted": 0
    }
    
    max_attempts = 3
    final_attempt_songs = []  # Track final attempt songs for fail-safe
    
    for attempt in range(1, max_attempts + 1):
        print(f"🎼 [WORKFLOW] === ATTEMPT {attempt}/{max_attempts} ===")
        
        attempt_details = {
            "attempt_number": attempt,
            "generation_success": False,
            "downloads": [],
            "reviews": [],
            "final_action": None
        }
        
        try:
            # STEP 1: Generate Song (creates 2 songs on Suno)
            print(f"🎼 [WORKFLOW] Step 1: Generating songs...")
            generation_result = await generate_songs(
                book_name, chapter, verse_range, style, title
            )
            
            if not generation_result["success"]:
                attempt_details["final_action"] = f"generation_failed: {generation_result['error']}"
                workflow_details["attempts"].append(attempt_details)
                continue
                
            attempt_details["generation_success"] = True
            workflow_details["total_songs_generated"] += 2  # Suno generates 2 songs
            
            # STEP 2: Wait for Suno processing
            print(f"🎼 [WORKFLOW] Step 2: Waiting for Suno processing (3 minutes)...")
            await asyncio.sleep(3 * 60)  # 3 minutes wait
            
            # STEP 3: Download both songs
            print(f"🎼 [WORKFLOW] Step 3: Downloading both generated songs...")
            download_results = await download_both_songs(title, temp_dir)
            
            if not download_results["success"]:
                attempt_details["final_action"] = f"download_failed: {download_results['error']}"
                workflow_details["attempts"].append(attempt_details)
                continue
                
            attempt_details["downloads"] = download_results["downloads"]
            downloaded_songs = download_results["downloads"]
            
            # Track final attempt songs for fail-safe mechanism
            if attempt == max_attempts:
                final_attempt_songs = downloaded_songs.copy()
                print(f"🎼 [WORKFLOW] Tracking {len(final_attempt_songs)} songs from final attempt for fail-safe")
            
            # STEP 4: Review both songs
            print(f"🎼 [WORKFLOW] Step 4: Reviewing {len(downloaded_songs)} downloaded songs...")
            review_results = await review_all_songs(downloaded_songs, song_structure_id)
            
            attempt_details["reviews"] = review_results
            workflow_details["total_songs_reviewed"] += len(review_results)
            
            # STEP 5: Process verdicts and handle files
            print(f"🎼 [WORKFLOW] Step 5: Processing review verdicts...")
            
            # Special handling for final attempt to preserve songs for fail-safe
            if attempt == max_attempts:
                verdict_result = await process_song_verdicts_final_attempt(review_results, final_dir)
            else:
                verdict_result = await process_song_verdicts(review_results, final_dir)
            
            workflow_details["songs_kept"] += verdict_result["kept_count"]
            workflow_details["songs_deleted"] += verdict_result["deleted_count"]
            
            # STEP 6: Check if we should continue or retry
            if verdict_result["kept_count"] > 0:
                # Success! At least one good song
                attempt_details["final_action"] = f"success: {verdict_result['kept_count']} songs kept"
                workflow_details["attempts"].append(attempt_details)
                
                return {
                    "success": True,
                    "message": f"🎼 Workflow completed successfully on attempt {attempt}!",
                    "total_attempts": attempt,
                    "final_songs_count": verdict_result["kept_count"], 
                    "good_songs": verdict_result["kept_count"],
                    "re_rolled_songs": verdict_result["deleted_count"],
                    "workflow_details": workflow_details
                }
            else:
                # All songs were bad, need to retry
                attempt_details["final_action"] = f"all_songs_rejected: retrying_attempt_{attempt + 1}"
                workflow_details["attempts"].append(attempt_details)
                print(f"🎼 [WORKFLOW] All songs rejected on attempt {attempt}, retrying...")
                
        except Exception as e:
            error_msg = f"Critical error on attempt {attempt}: {str(e)}"
            print(f"🎼 [WORKFLOW] {error_msg}")
            print(traceback.format_exc())
            
            attempt_details["final_action"] = f"exception: {error_msg}"
            workflow_details["attempts"].append(attempt_details)
            
            if attempt == max_attempts:
                # Last attempt failed, return error
                return {
                    "success": False,
                    "message": f"🎼 Workflow failed after {max_attempts} attempts",
                    "total_attempts": attempt,
                    "final_songs_count": 0,
                    "error": error_msg,
                    "workflow_details": workflow_details
                }
    
    # If we reach here, all attempts failed but no exception on last attempt
    # This means all songs were consistently rejected across all attempts
    print(f"🎼 [WORKFLOW] All {max_attempts} attempts completed, no songs met quality standards")
    
    # FAIL-SAFE: Move final attempt songs to final_review regardless of verdict
    failsafe_songs_moved = 0
    if final_attempt_songs:
        print(f"🎼 [WORKFLOW] 🛡️ FAIL-SAFE ACTIVATED: Moving {len(final_attempt_songs)} final attempt songs to final_review")
        failsafe_result = await handle_failsafe_songs(final_attempt_songs, final_dir)
        failsafe_songs_moved = failsafe_result["moved_count"]
        workflow_details["songs_kept"] += failsafe_songs_moved
        
        if failsafe_songs_moved > 0:
            return {
                "success": True,
                "message": f"🎼 Max attempts ({max_attempts}) reached. AI rejected all songs, but fail-safe activated: {failsafe_songs_moved} song(s) from final attempt moved to final_review as backup.",
                "total_attempts": max_attempts,
                "final_songs_count": failsafe_songs_moved,
                "good_songs": 0,  # None were AI-approved
                "re_rolled_songs": workflow_details["songs_deleted"],
                "workflow_details": workflow_details
            }
    
    return {
        "success": True,  # Technical success, but no quality songs
        "message": f"🎼 Max attempts ({max_attempts}) reached. All generated songs were rejected by AI review. No songs were successfully downloaded in final attempt.",
        "total_attempts": max_attempts,
        "final_songs_count": 0,
        "good_songs": 0,
        "re_rolled_songs": workflow_details["songs_deleted"],
        "workflow_details": workflow_details
    }


async def generate_songs(book_name: str, chapter: int, verse_range: str, style: str, title: str) -> Dict[str, Any]:
    """Generate songs using existing song generation handler."""
    try:
        from ..song.utils import generate_song_handler
        
        result = await generate_song_handler(
            strBookName=book_name,
            intBookChapter=chapter, 
            strVerseRange=verse_range,
            strStyle=style,
            strTitle=title
        )
        
        if result and isinstance(result, dict) and result.get("success"):
            return {"success": True, "result": result}
        else:
            return {"success": False, "error": "Song generation returned invalid result"}
            
    except Exception as e:
        return {"success": False, "error": f"Song generation failed: {str(e)}"}


async def download_both_songs(title: str, temp_dir: str) -> Dict[str, Any]:
    """Download both songs using negative indexing (-1, -2)."""
    try:
        from ..song.utils import download_song_handler
        
        downloaded_songs = []
        
        # Download song at index -1 (last/newest song)
        print(f"🎼 [DOWNLOAD] Downloading song at index -1...")
        download_1 = await download_song_handler(
            strTitle=title,
            intIndex=-1,
            download_path=temp_dir
        )
        
        if download_1["success"]:
            downloaded_songs.append({
                "file_path": download_1["file_path"],
                "index": -1,
                "title": title
            })
            print(f"🎼 [DOWNLOAD] Successfully downloaded song -1: {download_1['file_path']}")
        else:
            print(f"🎼 [DOWNLOAD] Failed to download song -1: {download_1.get('error')}")
        
        # Download song at index -2 (second to last song)
        print(f"🎼 [DOWNLOAD] Downloading song at index -2...")
        download_2 = await download_song_handler(
            strTitle=title,
            intIndex=-2,
            download_path=temp_dir
        )
        
        if download_2["success"]:
            downloaded_songs.append({
                "file_path": download_2["file_path"], 
                "index": -2,
                "title": title
            })
            print(f"🎼 [DOWNLOAD] Successfully downloaded song -2: {download_2['file_path']}")
        else:
            print(f"🎼 [DOWNLOAD] Failed to download song -2: {download_2.get('error')}")
        
        if len(downloaded_songs) == 0:
            return {
                "success": False, 
                "error": "Failed to download any songs",
                "downloads": []
            }
        elif len(downloaded_songs) == 1:
            print(f"🎼 [DOWNLOAD] Warning: Only downloaded 1 of 2 songs")
            
        return {
            "success": True,
            "downloads": downloaded_songs,
            "message": f"Downloaded {len(downloaded_songs)} of 2 songs"
        }
        
    except Exception as e:
        return {
            "success": False,
            "error": f"Download process failed: {str(e)}",
            "downloads": []
        }


async def review_all_songs(downloaded_songs: List[Dict], song_structure_id: int) -> List[Dict[str, Any]]:
    """Review all downloaded songs using AI review system."""
    review_results = []
    
    # Import the review functionality - we need to check what's available
    try:
        # This might need to be adjusted based on actual review endpoint location
        # For now, we'll create a placeholder that calls the review API
        for i, song in enumerate(downloaded_songs):
            print(f"🎼 [REVIEW] Reviewing song {i+1}/{len(downloaded_songs)}: {song['file_path']}")
            
            # TODO: Replace with actual review API call
            # This should call the existing review endpoint
            review_result = await call_review_api(song["file_path"], song_structure_id)
            
            review_results.append({
                "file_path": song["file_path"],
                "index": song["index"],
                "title": song["title"],
                "verdict": review_result.get("verdict", "error"),
                "review_details": review_result
            })
            
        return review_results
        
    except Exception as e:
        print(f"🎼 [REVIEW] Review process failed: {e}")
        # Return error verdicts for all songs
        return [{
            "file_path": song["file_path"],
            "index": song["index"], 
            "title": song["title"],
            "verdict": "error",
            "review_details": {"error": str(e)}
        } for song in downloaded_songs]


async def call_review_api(file_path: str, song_structure_id: int) -> Dict[str, Any]:
    """Call the AI review API for a single song."""
    try:
        # Import the actual review function from ai_review module
        from ..ai_review.routes import review_song_endpoint
        from ..ai_review.routes import SongReviewRequest
        
        print(f"🎼 [REVIEW_API] Calling AI review for: {file_path}")
        print(f"🎼 [REVIEW_API] Using song_structure_id: {song_structure_id}")
        
        # Create the review request
        review_request = SongReviewRequest(
            audio_file_path=file_path,
            song_structure_id=song_structure_id or 0  # Use 0 as fallback if None
        )
        
        # Call the review endpoint directly
        review_response = await review_song_endpoint(review_request)
        
        print(f"🎼 [REVIEW_API] Review completed. Verdict: {review_response.verdict}")
        
        return {
            "success": review_response.success,
            "verdict": review_response.verdict,
            "first_response": review_response.first_response,
            "second_response": review_response.second_response,
            "error": review_response.error,
            "audio_file": review_response.audio_file
        }
        
    except Exception as e:
        error_msg = f"AI review API call failed: {str(e)}"
        print(f"🎼 [REVIEW_API] {error_msg}")
        print(traceback.format_exc())
        
        return {
            "success": False,
            "verdict": "error", 
            "error": error_msg
        }


async def process_song_verdicts(review_results: List[Dict], final_dir: str) -> Dict[str, int]:
    """Process review verdicts: move good songs to final_review, delete bad ones."""
    kept_count = 0
    deleted_count = 0
    
    for result in review_results:
        file_path = result["file_path"]
        verdict = result["verdict"]
        
        try:
            if verdict == "continue":
                # Move to final_review directory - THIS IS THE VERIFIED FINAL DESTINATION
                filename = os.path.basename(file_path)
                final_path = os.path.join(final_dir, filename)
                
                if os.path.exists(file_path):
                    shutil.move(file_path, final_path)
                    kept_count += 1
                    print(f"🎼 [VERDICT] ✅ APPROVED SONG moved to final destination: {final_path}")
                    print(f"🎼 [VERDICT] ✅ CONFIRMED: Song is now in backend/songs/final_review directory")
                else:
                    print(f"🎼 [VERDICT] ⚠️ File not found for moving: {file_path}")
                    
            elif verdict == "re-roll":
                # Delete the file
                if os.path.exists(file_path):
                    os.remove(file_path)
                    deleted_count += 1
                    print(f"🎼 [VERDICT] ❌ Deleted poor quality song: {file_path}")
                else:
                    print(f"🎼 [VERDICT] ⚠️ File not found for deletion: {file_path}")
                    
            else:  # verdict == "error" or unknown
                # Keep file in temp directory but don't count as success
                print(f"🎼 [VERDICT] ⚠️ Review error, leaving in temp: {file_path}")
                
        except Exception as e:
            print(f"🎼 [VERDICT] Error processing {file_path}: {e}")
    
    return {
        "kept_count": kept_count,
        "deleted_count": deleted_count
    }


async def process_song_verdicts_final_attempt(review_results: List[Dict], final_dir: str) -> Dict[str, int]:
    """
    Process verdicts for the final attempt with special handling to preserve songs for fail-safe.
    
    On the final attempt, we only move "continue" songs but don't delete "re-roll" songs.
    The "re-roll" songs are preserved in temp directory for potential fail-safe recovery.
    
    Args:
        review_results (List[Dict]): Review results from AI
        final_dir (str): Final review directory path
        
    Returns:
        Dict[str, int]: Processing results
    """
    kept_count = 0
    deleted_count = 0
    preserved_count = 0
    
    print(f"🎼 [VERDICT-FINAL] Processing final attempt verdicts (preserving re-roll songs for fail-safe)")
    
    for result in review_results:
        file_path = result["file_path"]
        verdict = result["verdict"]
        
        try:
            if verdict == "continue":
                # Move good songs to final_review as usual - VERIFIED FINAL DESTINATION
                filename = os.path.basename(file_path)
                final_path = os.path.join(final_dir, filename)
                
                if os.path.exists(file_path):
                    shutil.move(file_path, final_path)
                    kept_count += 1
                    print(f"🎼 [VERDICT-FINAL] ✅ APPROVED SONG moved to final destination: {final_path}")
                    print(f"🎼 [VERDICT-FINAL] ✅ CONFIRMED: Song is now in backend/songs/final_review directory")
                else:
                    print(f"🎼 [VERDICT-FINAL] ⚠️ File not found for moving: {file_path}")
                    
            elif verdict == "re-roll":
                # SPECIAL: Don't delete re-roll songs on final attempt - preserve for fail-safe
                if os.path.exists(file_path):
                    preserved_count += 1
                    print(f"🎼 [VERDICT-FINAL] 🛡️ Preserved re-roll song for fail-safe: {file_path}")
                else:
                    print(f"🎼 [VERDICT-FINAL] ⚠️ Re-roll song file not found: {file_path}")
                    
            else:  # verdict == "error" or unknown
                # Keep file in temp directory for fail-safe consideration
                preserved_count += 1
                print(f"🎼 [VERDICT-FINAL] ⚠️ Review error, preserving for fail-safe: {file_path}")
                
        except Exception as e:
            print(f"🎼 [VERDICT-FINAL] Error processing {file_path}: {e}")
    
    print(f"🎼 [VERDICT-FINAL] Final attempt results: {kept_count} kept, {preserved_count} preserved for fail-safe")
    
    return {
        "kept_count": kept_count,
        "deleted_count": deleted_count,  # No deletions on final attempt
        "preserved_count": preserved_count
    }


def verify_final_destination_folder() -> str:
    """
    🔍 VERIFICATION: Confirm the final destination folder for approved songs.
    
    This function serves as a single source of truth for the final destination
    and provides verification that we're using the correct folder path.
    
    Returns:
        str: The verified final destination folder path
    """
    final_destination = "backend/songs/final_review"
    
    print(f"🔍 [VERIFY] Final destination folder confirmed: {final_destination}")
    print(f"🔍 [VERIFY] This is where ALL approved songs will be moved:")
    print(f"🔍 [VERIFY]   - AI-approved songs (verdict: 'continue')")
    print(f"🔍 [VERIFY]   - Fail-safe backup songs (marked with '_FAILSAFE')")
    
    return final_destination


async def handle_failsafe_songs(final_attempt_songs: List[Dict], final_dir: str) -> Dict[str, int]:
    """
    🛡️ FAIL-SAFE MECHANISM: Move final attempt songs to final_review regardless of review verdict.
    
    This function is called when all 3 attempts fail to produce AI-approved songs.
    It ensures that the work from the final attempt isn't lost by moving downloaded
    songs to the final_review directory as a backup.
    
    Args:
        final_attempt_songs (List[Dict]): Songs downloaded in the final attempt
        final_dir (str): Path to final_review directory
        
    Returns:
        Dict[str, int]: Results with moved_count and error_count
    """
    moved_count = 0
    error_count = 0
    
    print(f"🛡️ [FAIL-SAFE] Processing {len(final_attempt_songs)} songs from final attempt")
    
    for i, song in enumerate(final_attempt_songs, 1):
        file_path = song["file_path"]
        
        try:
            if os.path.exists(file_path):
                # Create fail-safe filename with clear labeling
                original_filename = os.path.basename(file_path)
                name_part, ext = os.path.splitext(original_filename)
                failsafe_filename = f"{name_part}_FAILSAFE{ext}"
                final_path = os.path.join(final_dir, failsafe_filename)
                
                # Move the file to VERIFIED FINAL DESTINATION
                shutil.move(file_path, final_path)
                moved_count += 1
                print(f"🛡️ [FAIL-SAFE] ✅ BACKUP SONG moved to final destination: {final_path}")
                print(f"🛡️ [FAIL-SAFE] ✅ CONFIRMED: Backup song {i}/{len(final_attempt_songs)} is now in backend/songs/final_review directory")
            else:
                error_count += 1
                print(f"🛡️ [FAIL-SAFE] ⚠️ File not found: {file_path}")
                
        except Exception as e:
            error_count += 1
            print(f"🛡️ [FAIL-SAFE] ❌ Error moving {file_path}: {e}")
    
    print(f"🛡️ [FAIL-SAFE] Completed: {moved_count} songs moved, {error_count} errors")
    
    return {
        "moved_count": moved_count,
        "error_count": error_count
    }
