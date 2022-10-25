/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_videotoolbox.h>

#include "common/common.h"
#include "osdep/timer.h"
#include "vo.h"
#include "video/mp_image.h"
#include "video/hwdec.h"

#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>

struct priv {
    struct mp_hwdec_ctx hwctx;

    struct mp_image *next_image;
    int64_t next_vo_pts;
    __strong AVSampleBufferDisplayLayer *displayLayer;
};

static AVBufferRef *create_videotoolbox_device_ref(struct vo *vo)
{
    AVBufferRef *device_ref = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);
    if (!device_ref)
        return NULL;

    if (av_hwdevice_ctx_init(device_ref) < 0)
        av_buffer_unref(&device_ref);

    return device_ref;
}

static int preinit(struct vo *vo)
{
    struct priv *p = vo->priv;

    if (!vo->opts->WinID) {
        MP_ERR(vo, "No AVSampleBufferDisplayLayer provided via --wid\n");
        return -1;
    }
    p->displayLayer = (__bridge AVSampleBufferDisplayLayer *)(intptr_t)(vo->opts->WinID);

    vo->hwdec_devs = hwdec_devices_create();
    p->hwctx = (struct mp_hwdec_ctx){
        .driver_name = "avfoundation",
        .av_device_ref = create_videotoolbox_device_ref(vo),
    };
    hwdec_devices_add(vo->hwdec_devs, &p->hwctx);

    return 0;
}

static void flip_page(struct vo *vo)
{
    struct priv *p = vo->priv;
    struct mp_image *img = p->next_image;

    if (!img)
        return;

    CVPixelBufferRef pixbuf = (CVPixelBufferRef)img->planes[3];
    CMSampleTimingInfo info = {
        .presentationTimeStamp = kCMTimeZero,
        .duration = kCMTimeInvalid,
        .decodeTimeStamp = kCMTimeInvalid
    };

    CMSampleBufferRef buf = NULL;
    CMFormatDescriptionRef format = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixbuf, &format);
    CMSampleBufferCreateReadyWithImageBuffer(
        NULL,
        pixbuf,
        format,
        &info,
        &buf
    );
    CFRelease(format);

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(buf, YES);
    CFDictionarySetValue(
        (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
        kCMSampleAttachmentKey_DisplayImmediately,
        kCFBooleanTrue
    );

    [p->displayLayer enqueueSampleBuffer:buf];

    CFRelease(buf);
    mp_image_unrefp(&p->next_image);
}

static void draw_frame(struct vo *vo, struct vo_frame *frame)
{
    struct priv *p = vo->priv;

    mp_image_t *mpi = NULL;
    if (!frame->redraw && !frame->repeat)
        mpi = mp_image_new_ref(frame->current);

    talloc_free(p->next_image);
    p->next_image = mpi;
    p->next_vo_pts = frame->pts;
}

static int query_format(struct vo *vo, int format)
{
    return format == IMGFMT_VIDEOTOOLBOX;
}

static int reconfig(struct vo *vo, struct mp_image_params *params)
{
    return 0;
}

static void uninit(struct vo *vo)
{
    struct priv *p = vo->priv;
    mp_image_unrefp(&p->next_image);

    [p->displayLayer flushAndRemoveImage];

    hwdec_devices_remove(vo->hwdec_devs, &p->hwctx);
    av_buffer_unref(&p->hwctx.av_device_ref);
}

static int control(struct vo *vo, uint32_t request, void *data)
{
    return VO_NOTIMPL;
}


#define OPT_BASE_STRUCT struct priv
static const struct m_option options[] = {
    {0},
};

const struct vo_driver video_out_avfoundation = {
    .description = "AVFoundation AVSampleBufferDisplayLayer (macOS/iOS)",
    .name = "avfoundation",
    .caps = VO_CAP_NORETAIN,
    .preinit = preinit,
    .query_format = query_format,
    .control = control,
    .draw_frame = draw_frame,
    .flip_page = flip_page,
    .reconfig = reconfig,
    .uninit = uninit,
    .priv_size = sizeof(struct priv),
    .options = options,
    .options_prefix = "avfoundation",
};