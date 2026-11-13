// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

#include <ngs/modules/envelope.h>
#include <util/log.h>

#include <algorithm>
#include <cmath>

namespace ngs {

// Amplitude envelope (ADSR-style points). Without it, every voice routed through an envelope played at
// full volume from its first sample: no fade-in, no decay to the sustain level, and lines that a game
// shapes or quiets with the envelope came out at the wrong level. A keyed-off voice still stops at once
// (as sceNgsVoiceKeyOff does in this NGS), so the release time is not used.

static float point_amplitude(const SceNgsEnvelopeParams *params, const int32_t count, const int32_t index) {
    const float amplitude = params->envelopePoints[std::clamp(index, 0, count - 1)].fAmplitude;
    return std::isfinite(amplitude) ? std::clamp(amplitude, 0.0f, 16.0f) : 1.0f;
}

void EnvelopeModule::on_state_change(const MemState &mem, ModuleData &data, const VoiceState previous) {
    if (data.parent->state == VOICE_STATE_ACTIVE && previous == VOICE_STATE_AVAILABLE) {
        EnvelopeLogicalState *logical = data.get_logical_state<EnvelopeLogicalState>();
        logical->current_point = 0;
        logical->position_in_segment_ms = 0.0;
        logical->total_position_ms = 0.0;
    }
}

bool EnvelopeModule::process(KernelState &kern, const MemState &mem, const SceUID thread_id, ModuleData &data, std::unique_lock<std::recursive_mutex> &scheduler_lock, std::unique_lock<std::mutex> &voice_lock) {
    if (data.is_bypassed)
        return false;
    const SceNgsEnvelopeParams *params = data.get_parameters<SceNgsEnvelopeParams>(mem);
    if (!params || params->desc.id != SCE_NGS_ENVELOPE_PARAMS_STRUCT_ID)
        return false;
    const int32_t count = static_cast<int32_t>(std::min<uint32_t>(params->uNumPoints, SCE_NGS_ENVELOPE_MAX_POINTS));
    if (count <= 0)
        return false;

    Voice *voice = data.parent;
    const int32_t granularity = voice->rack->system->granularity;
    const int32_t sample_rate = voice->rack->system->sample_rate;
    if (granularity <= 0 || sample_rate <= 0)
        return false;

    EnvelopeLogicalState *logical = data.get_logical_state<EnvelopeLogicalState>();
    logical->current_point = std::clamp(logical->current_point, 0, count - 1);

    // A loop between two points; a loop on a single point holds it (the usual sustain)
    const int32_t loop_start = static_cast<int32_t>(params->uLoopStart);
    const int32_t loop_end = params->nLoopEnd;
    const bool looping = loop_end >= 0 && loop_end < count && loop_start >= 0 && loop_start <= loop_end;

    const auto gain_now = [&]() -> float {
        const int32_t point = logical->current_point;
        const float from = point_amplitude(params, count, point);
        if (point >= count - 1 || (looping && loop_start == loop_end && point == loop_end))
            return from;
        const float to = point_amplitude(params, count, point + 1);
        const double length = params->envelopePoints[point].uMsecsToNextPoint;
        if (length <= 0.0)
            return to;
        double t = std::clamp(logical->position_in_segment_ms / length, 0.0, 1.0);
        if (params->envelopePoints[point].eCurveType == SCE_NGS_ENVELOPE_CURVED)
            t = t * t * (3.0 - 2.0 * t);
        return static_cast<float>(from + (to - from) * t);
    };

    const float start_gain = gain_now();
    const double tick_ms = static_cast<double>(granularity) * 1000.0 / static_cast<double>(sample_rate);
    logical->total_position_ms += tick_ms;
    logical->position_in_segment_ms += tick_ms;
    // Move through finished segments (a segment of length 0 is passed at once; at most a few per tick)
    for (int32_t guard = 0; guard < SCE_NGS_ENVELOPE_MAX_POINTS * 2 && logical->current_point < count - 1; guard++) {
        if (looping && loop_start == loop_end && logical->current_point == loop_end)
            break;
        const double length = params->envelopePoints[logical->current_point].uMsecsToNextPoint;
        if (logical->position_in_segment_ms < length)
            break;
        logical->position_in_segment_ms -= length;
        logical->current_point++;
        if (looping && loop_start < loop_end && logical->current_point == loop_end)
            logical->current_point = loop_start;
    }
    const float end_gain = gain_now();

    if (SceNgsEnvelopeStates *state = data.get_state<SceNgsEnvelopeStates>()) {
        state->fCurrentHeight = end_gain;
        state->fPosition = static_cast<float>(logical->total_position_ms);
        state->fReleaseScale = 1.0f;
        state->nCurrentPoint = logical->current_point;
        state->nReleasing = 0;
    }

    // Applied to the signal the voice carries so far, ramped across the tick (no zipper noise)
    float *signal = reinterpret_cast<float *>(voice->products[0].data);
    if (signal && !(start_gain == 1.0f && end_gain == 1.0f)) {
        const float step = (end_gain - start_gain) / static_cast<float>(granularity);
        float gain = start_gain;
        for (int32_t frame = 0; frame < granularity; frame++) {
            signal[frame * 2 + 0] *= gain;
            signal[frame * 2 + 1] *= gain;
            gain += step;
        }
    }
    return false;
}

} // namespace ngs
