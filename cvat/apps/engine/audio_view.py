"""
FILE: cvat/apps/engine/audio_view.py

New Django REST endpoint that extracts and serves the audio track
from a CVAT task's uploaded video file.

HOW TO WIRE THIS IN:
1. Copy this file to: cvat/apps/engine/audio_view.py
2. In cvat/apps/engine/views.py, find the TaskViewSet class and add
   this import at the top of the file:
       from cvat.apps.engine.audio_view import audio_endpoint
3. Add the action method shown at the bottom of this file into TaskViewSet.

OR use the standalone view registration shown at the very bottom.
"""

import os
import subprocess
import hashlib
import logging
from pathlib import Path

from django.http import FileResponse, HttpResponse
from django.conf import settings
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework import status

logger = logging.getLogger(__name__)

# Cache extracted audio files in a subdirectory of CVAT's data root
# CVAT stores task data under settings.CVAT_ROOT / 'data' / str(task_id)
AUDIO_CACHE_DIR = Path(getattr(settings, 'CVAT_ROOT', '/home/django/data')) / 'audio_cache'


def get_task_video_path(task) -> Path | None:
    """
    Find the original video file for a CVAT task.

    CVAT stores uploaded video under:
        <CVAT_ROOT>/data/<task_id>/raw/  (older versions)
        <CVAT_ROOT>/data/<task_id>/original/  (newer versions)
    The exact location depends on CVAT version; we search both.
    """
    task_data_dir = Path(task.get_data_dirname())

    # Search common CVAT video storage locations
    search_paths = [
        task_data_dir / 'raw',
        task_data_dir / 'original',
        task_data_dir,
        task_data_dir / 'data',
    ]

    video_extensions = {'.mp4', '.avi', '.mov', '.mkv', '.webm', '.m4v'}

    for search_dir in search_paths:
        if not search_dir.exists():
            continue
        for f in search_dir.iterdir():
            if f.suffix.lower() in video_extensions:
                return f

    return None


def has_audio_track(video_path: Path) -> bool:
    """
    Use ffprobe to check if the video file has at least one audio stream.
    Returns False if ffprobe is unavailable or the video has no audio.
    """
    try:
        result = subprocess.run(
            [
                'ffprobe', '-v', 'quiet',
                '-select_streams', 'a:0',
                '-show_entries', 'stream=codec_type',
                '-of', 'default=noprint_wrappers=1:nokey=1',
                str(video_path),
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() == 'audio'
    except (subprocess.TimeoutExpired, FileNotFoundError):
        logger.warning('ffprobe not available or timed out for %s', video_path)
        return False


def extract_audio(video_path: Path, task_id: int) -> Path | None:
    """
    Extract the audio track from a video file using ffmpeg.
    The result is cached so repeated requests don't re-process.

    Returns the path to the extracted MP3 file, or None on failure.
    """
    AUDIO_CACHE_DIR.mkdir(parents=True, exist_ok=True)

    # Use a hash of the video path as the cache key so filenames are stable
    cache_key = hashlib.md5(str(video_path).encode()).hexdigest()
    audio_path = AUDIO_CACHE_DIR / f'task_{task_id}_{cache_key}.mp3'

    # Return cached version if it exists and is non-empty
    if audio_path.exists() and audio_path.stat().st_size > 0:
        logger.info('Returning cached audio for task %d: %s', task_id, audio_path)
        return audio_path

    logger.info('Extracting audio for task %d from %s', task_id, video_path)

    try:
        result = subprocess.run(
            [
                'ffmpeg',
                '-i', str(video_path),   # input video
                '-vn',                    # no video in output
                '-acodec', 'libmp3lame', # encode as MP3
                '-ab', '128k',           # 128kbps is sufficient for speech
                '-ar', '44100',          # standard sample rate
                '-y',                    # overwrite if exists
                str(audio_path),
            ],
            capture_output=True,
            timeout=120,  # 2 minutes max for long videos
        )

        if result.returncode != 0:
            logger.error(
                'ffmpeg failed for task %d: %s',
                task_id,
                result.stderr.decode(errors='replace')[:500],
            )
            return None

        return audio_path

    except subprocess.TimeoutExpired:
        logger.error('ffmpeg timed out for task %d', task_id)
        # Clean up partial file
        if audio_path.exists():
            audio_path.unlink(missing_ok=True)
        return None
    except FileNotFoundError:
        logger.error('ffmpeg not found — install it in the Docker image')
        return None


# ── Django REST Framework action ──────────────────────────────────────────────
# Add this method to the TaskViewSet class in cvat/apps/engine/views.py
#
# COPY EVERYTHING BETWEEN THE DASHED LINES INTO TaskViewSet:
# ─────────────────────────────────────────────────────────────
#
#   @action(detail=True, methods=['GET'], url_path='audio', url_name='audio')
#   def audio(self, request, pk=None):
#       from cvat.apps.engine.audio_view import get_task_video_path, has_audio_track, extract_audio
#       task = self.get_object()
#
#       video_path = get_task_video_path(task)
#       if video_path is None:
#           return Response(
#               {'error': 'No video file found for this task'},
#               status=status.HTTP_404_NOT_FOUND,
#           )
#
#       if not has_audio_track(video_path):
#           # 204 No Content tells the frontend "video exists but has no audio"
#           return HttpResponse(status=204)
#
#       audio_path = extract_audio(video_path, task.id)
#       if audio_path is None:
#           return Response(
#               {'error': 'Audio extraction failed'},
#               status=status.HTTP_500_INTERNAL_SERVER_ERROR,
#           )
#
#       response = FileResponse(
#           open(audio_path, 'rb'),
#           content_type='audio/mpeg',
#           filename=f'task_{task.id}_audio.mp3',
#       )
#       # Allow browser to cache the audio file (1 hour)
#       response['Cache-Control'] = 'public, max-age=3600'
#       return response
#
# ─────────────────────────────────────────────────────────────


# ── Standalone version for direct testing ─────────────────────────────────────
# You can also test the audio extraction logic independently:
#
#   python manage.py shell
#   >>> from cvat.apps.engine.audio_view import extract_audio
#   >>> from pathlib import Path
#   >>> result = extract_audio(Path('/path/to/video.mp4'), task_id=1)
#   >>> print(result)
