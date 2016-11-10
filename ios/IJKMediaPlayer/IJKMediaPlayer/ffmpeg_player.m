//
//  ffmpeg_player.c
//  IJKMediaPlayer
//
//  Created by Nipun Kwatra on 11/9/16.
//  Copyright © 2016 bilibili. All rights reserved.
//

#include "ffmpeg_player.h"

#include "config.h"
#include <inttypes.h>
#include <math.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>

#include "libavutil/avstring.h"
#include "libavutil/eval.h"
#include "libavutil/mathematics.h"
#include "libavutil/pixdesc.h"
#include "libavutil/imgutils.h"
#include "libavutil/dict.h"
#include "libavutil/parseutils.h"
#include "libavutil/samplefmt.h"
#include "libavutil/avassert.h"
#include "libavutil/time.h"
#include "libavformat/avc.h"
#include "libavformat/avformat.h"
//#include "libavdevice/avdevice.h"
#include "libswscale/swscale.h"
#include "libavutil/opt.h"
#include "libavcodec/avfft.h"
#include "libswresample/swresample.h"


#import <CoreMedia/CoreMedia.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreVideo/CVHostTime.h>
#import <Foundation/Foundation.h>

#include "IJKVideoToolBox.h"

/* options specified by the user */
static int audio_disable = 0;
static int video_disable = 0;
static int subtitle_disable = 0;

typedef struct FFVideoState {
    int abort_request;
    int queue_attachments_req;
    AVFormatContext *ic;

    int av_sync_type;

    int subtitle_stream;
    AVStream *subtitle_st;
    
    int audio_stream;
    AVStream *audio_st;
    
    int video_stream;
    AVStream *video_st;
    VTBFormatDesc video_fmt_desc;
    
    
    int eof;

    char *filename;
    int width, height;
} FFVideoState;

static int init_stream(FFVideoState *is);
static int init_stream_for_type(FFVideoState *is, int stream_index, int stream_type);
static int vtbformat_init_my(VTBFormatDesc *fmt_desc, AVCodecParameters *codecpar);

static int decode_interrupt_cb(void *ctx) {
    FFVideoState *is = ctx;
    return is->abort_request;
}

static void stream_component_close(FFVideoState *is, int stream_index) {
    AVFormatContext *ic = is->ic;

    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return;
    
    AVCodecParameters *codecpar;
    codecpar = ic->streams[stream_index]->codecpar;

    ic->streams[stream_index]->discard = AVDISCARD_ALL;
    switch (codecpar->codec_type) {
    case AVMEDIA_TYPE_AUDIO:
        is->audio_st = NULL;
        is->audio_stream = -1;
        break;
    case AVMEDIA_TYPE_VIDEO:
        is->video_st = NULL;
        is->video_stream = -1;
        break;
    case AVMEDIA_TYPE_SUBTITLE:
        is->subtitle_st = NULL;
        is->subtitle_stream = -1;
        break;
    default:
        break;
    }
}

static void stream_close(FFVideoState *is) {
    /* XXX: use a special url_shutdown call to abort parse cleanly */
    is->abort_request = 1;

    /* close each stream */
    if (is->audio_stream >= 0)
        stream_component_close(is, is->audio_stream);
    if (is->video_stream >= 0)
        stream_component_close(is, is->video_stream);
    if (is->subtitle_stream >= 0)
        stream_component_close(is, is->subtitle_stream);

    avformat_close_input(&is->ic);

    /* free all pictures */
    av_free(is->filename);
    av_free(is);
}

static FFVideoState *stream_open(const char *filename) {
    FFVideoState *is;

    is = av_mallocz(sizeof(FFVideoState));
    if (!is)
        return NULL;
    is->filename = av_strdup(filename);
    if (!is->filename) {
        stream_close(is);
        return NULL;
    }
    
    init_stream(is);
    
    /* start video display */
    return is;
}

static int init_stream(FFVideoState *is) {
//static int read_thread(void *arg)
    AVFormatContext *ic = NULL;
    int err;

    // Open video file and read context into AVFormatContext ic.
    ic = avformat_alloc_context();
    if (!ic) {
        av_log(NULL, AV_LOG_FATAL, "Could not allocate context.\n");
        return -1;
    }
    ic->interrupt_callback.callback = decode_interrupt_cb;
    ic->interrupt_callback.opaque = is;
    
    err = avformat_open_input(&ic, is->filename, NULL, NULL);
    if (err < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not open file: %s.\n", is->filename);
        avformat_close_input(&ic);
        return -1;
    }
    is->ic = ic;

    // This function will cause global side data to be injected in the next packet of each stream as well as after any subsequent seek.
    av_format_inject_global_side_data(ic);

    // Read packets of a media file to get stream information.
    err = avformat_find_stream_info(ic, NULL);
    if (err < 0) {
        av_log(NULL, AV_LOG_WARNING,
               "%s: could not find codec parameters\n", is->filename);
        return -1;
    }

    if (ic->pb)
        ic->pb->eof_reached = 0; // FIXME hack, ffplay maybe should not use avio_feof() to test for the end

    // Find the right streams.
    int st_index[AVMEDIA_TYPE_NB];
    memset(st_index, -1, sizeof(st_index));
    if (!video_disable)
        st_index[AVMEDIA_TYPE_VIDEO] =
            av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO,
                                -1, -1, NULL, 0);
    if (!audio_disable)
        st_index[AVMEDIA_TYPE_AUDIO] =
            av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO,
                                -1,
                                st_index[AVMEDIA_TYPE_VIDEO],
                                NULL, 0);
    if (!video_disable && !subtitle_disable)
        st_index[AVMEDIA_TYPE_SUBTITLE] =
            av_find_best_stream(ic, AVMEDIA_TYPE_SUBTITLE,
                                -1,
                                (st_index[AVMEDIA_TYPE_AUDIO] >= 0 ?
                                 st_index[AVMEDIA_TYPE_AUDIO] :
                                 st_index[AVMEDIA_TYPE_VIDEO]),
                                NULL, 0);

    /* open the streams */
    if (st_index[AVMEDIA_TYPE_AUDIO] >= 0) {
        init_stream_for_type(is, st_index[AVMEDIA_TYPE_AUDIO], AVMEDIA_TYPE_AUDIO);
    }
    if (st_index[AVMEDIA_TYPE_VIDEO] >= 0) {
        init_stream_for_type(is, st_index[AVMEDIA_TYPE_VIDEO], AVMEDIA_TYPE_VIDEO);
    }
    if (st_index[AVMEDIA_TYPE_SUBTITLE] >= 0) {
        init_stream_for_type(is, st_index[AVMEDIA_TYPE_SUBTITLE], AVMEDIA_TYPE_SUBTITLE);
    }

    if (is->video_stream < 0 && is->audio_stream < 0) {
        av_log(NULL, AV_LOG_FATAL, "Failed to open file '%s' or configure filtergraph\n",
               is->filename);
        return -1;
    }
    return 1;
}

static int init_stream_for_type(FFVideoState *is, int stream_index, int stream_type) {
    AVFormatContext *ic = is->ic;
    if (stream_index < 0 || stream_index >= ic->nb_streams)
        return -1;

    is->eof = 0;
    ic->streams[stream_index]->discard = AVDISCARD_DEFAULT;
    switch (stream_type) {
    case AVMEDIA_TYPE_AUDIO:
        is->audio_stream = stream_index;
        is->audio_st = ic->streams[stream_index];
        break;
    case AVMEDIA_TYPE_VIDEO:
        is->video_stream = stream_index;
        is->video_st = ic->streams[stream_index];
            
        if (vtbformat_init_my(&(is->video_fmt_desc), is->video_st->codecpar) < 0) {
            av_log(NULL, AV_LOG_ERROR, "Failed to get vtb format for: %s\n", is->filename);
            return -1;
        }
            
        break;
    case AVMEDIA_TYPE_SUBTITLE:
        is->subtitle_stream = stream_index;
        is->subtitle_st = ic->streams[stream_index];
        break;
    default:
        break;
    }

    return 1;
}


// MARK: VideoToolBox

static int vtbformat_init_my(VTBFormatDesc *fmt_desc, AVCodecParameters *codecpar) {
    return vtbformat_init_wrapper(fmt_desc, codecpar);
}

// Copied from h264_sps_parser.h
#define AV_RB24(x)                          \
((((const uint8_t*)(x))[0] << 16) |        \
(((const uint8_t*)(x))[1] <<  8) |        \
((const uint8_t*)(x))[2])


static CMSampleBufferRef create_sample_buffer(VTBFormatDesc* fmt_desc, const AVPacket *avpkt) {
    CMSampleBufferRef sample_buff   = NULL;
    AVIOContext *pb                 = NULL;
    int demux_size                  = 0;
    uint8_t *demux_buff             = NULL;
    uint8_t *pData                  = avpkt->data;
    int iSize                       = avpkt->size;

    if (fmt_desc->convert_bytestream) {
        // ALOGI("the buffer should m_convert_byte\n");
        if(avio_open_dyn_buf(&pb) < 0) {
            goto failed;
        }
        ff_avc_parse_nal_units(pb, pData, iSize);
        demux_size = avio_close_dyn_buf(pb, &demux_buff);
        // ALOGI("demux_size:%d\n", demux_size);
        if (demux_size == 0) {
            goto failed;
        }
        sample_buff = CreateSampleBufferFrom_wrapper(fmt_desc->fmt_desc, demux_buff, demux_size);
    } else if (fmt_desc->convert_3byteTo4byteNALSize) {
        // ALOGI("3byteto4byte\n");
        if (avio_open_dyn_buf(&pb) < 0) {
            goto failed;
        }

        uint32_t nal_size;
        uint8_t *end = avpkt->data + avpkt->size;
        uint8_t *nal_start = pData;
        while (nal_start < end) {
            nal_size = AV_RB24(nal_start);
            avio_wb32(pb, nal_size);
            nal_start += 3;
            avio_write(pb, nal_start, nal_size);
            nal_start += nal_size;
        }
        demux_size = avio_close_dyn_buf(pb, &demux_buff);
        sample_buff = CreateSampleBufferFrom_wrapper(fmt_desc->fmt_desc, demux_buff, demux_size);
    } else {
        sample_buff = CreateSampleBufferFrom_wrapper(fmt_desc->fmt_desc, pData, iSize);
    }
    if (!sample_buff) {
        if (demux_size) {
            av_free(demux_buff);
        }
        ALOGI("%s - CreateSampleBufferFrom failed", __FUNCTION__);
        goto failed;
    }

    //if (sample_buff) {
    //    CFRelease(sample_buff);
    //}
    //if (demux_size) {
    //    av_free(demux_buff);
    //}
    
    return sample_buff;

failed:
    if (sample_buff) {
        CFRelease(sample_buff);
    }
    if (demux_size) {
        av_free(demux_buff);
    }
    return NULL;
}

// MARK Player interface.

@implementation FFMpegPlayer

- (instancetype)initWithFilePath:(NSString *)filePath {
    self = [super init];
    if (self) {
        _videoState = stream_open([filePath UTF8String]);
        if (_videoState == NULL) {
            //[self release];
            return nil;
        }
    }
    return self;
}

- (CMSampleBufferRef)readNextSampleBuffer {
    AVPacket pkt;
    av_read_frame(_videoState->ic, &pkt);
    return create_sample_buffer(&(_videoState->video_fmt_desc), &pkt);
}

@end




