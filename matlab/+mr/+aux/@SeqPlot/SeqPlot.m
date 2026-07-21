classdef SeqPlot < handle
    %plot Plot the sequence in a new figure.
    %   plot(seqObj) Plot the sequence
    %
    %   plot(...,'timeRange',[start stop]) Plot the sequence
    %   between the times specified by start and stop.
    %
    %   plot(...,'blockRange',[first last]) Plot the sequence
    %   starting from the first specified block to the last one.
    %
    %   plot(...,'timeDisp',unit) Display time in:
    %   's', 'ms' or 'us'.
    %
    %   plot(...,'label','LIN,REP') Plot label values for ADC events:
    %   in this example for LIN and REP labels; other valid labes are
    %   accepted as a comma-separated list.
    %
    %   plot(...,'showBlocks',1) Plot grid and tick labels at the
    %   block boundaries. Accepts a numeric or a boolean parameter.
    %
    %   plot(...,'stacked',1) Rearrange the plots such they are vertically
    %   stacked and share the same x-axis. Accepts a numeric or a boolean
    %   parameter.
    %
    %   plot(...,'showGuides',1) How dynamic hairline guides that follow
    %   the data cursor to help verifying event alignment. Accepts a
    %   numeric or a boolean parameter.
    %
    %   plot(...,'showLimits',1) Plot the system limits (maxGrad on the
    %   Gx/Gy/Gz axes and maxB1 on the RF magnitude axis) as dashed red
    %   reference lines. Accepts a numeric or a boolean parameter,
    %   defaults to true; set to 0 to hide the limit lines.
    %
    %   plot(...,'showSlew',1) Additionally plot the slew rate of each
    %   gradient channel (in kHz/m/ms) as a stairstep plot on its own
    %   axis directly below the corresponding gradient axis. With
    %   'showLimits' enabled, maxSlew is shown as dashed red reference
    %   lines. Accepts a numeric or a boolean parameter, defaults to
    %   false.
    %
    %   plot(...,'extra',extra) Plot additional, caller-supplied waveforms
    %   that are not derived from the seq object, each on its own new axis
    %   appended after the built-in ones. extra is a struct array with
    %   fields:
    %     t        time vector, in seconds (same convention as the rest of
    %              the plot -- not pre-scaled by 'timeDisp'). May instead be
    %              a cell array of vectors to plot multiple traces sharing
    %              one axis.
    %     waveform data vector matching t (or a matching cell array).
    %     label    y-axis label string for this axis (optional; defaults
    %              to 'extra N').
    %     name     cell array of legend entries, one per trace (optional;
    %              only used when t/waveform are cell arrays).
    %   Example:
    %     extra(1).t = t1; extra(1).waveform = w1; extra(1).label = 'PNS prediction (a.u.)';
    %     seq.plot('extra',extra)
    %
    %   Press and drag the middle mouse button (or shift+left-click-drag)
    %   anywhere in the figure to pan (left/right motion) and zoom
    %   (up/down motion, drag up = zoom in) the visible time range; y-axis
    %   scales are never affected by this gesture.
    %
    %   f=plot(...) Return the new figure handle.
    %

    properties (Access = public)
        f   % figure handle
    end

    properties (Access = private)
        ax % array of plot axes handles
        vLines  % array of vline handles

        hSeq

        labels          % cell array of waveform names, one per axis
        axVisible       % logical vector, current visibility of each axis
        stackedMode     % logical, whether the stacked layout is active
        slewAxIdx       % indices into obj.ax of the SRx/SRy/SRz axes (7:9), [] when 'showSlew' is off
        extraAxIdx      % indices into obj.ax of the user-supplied 'extra' axes, [] when none
        axColumns       % cell array of axis-index vectors, one per column of the (non-stacked) grid layout, top-to-bottom order within each
        axStackOrder    % axis indices in top-to-bottom order for the stacked layout
        xLabelStr       % x-axis label string, e.g. 't (ms)'
        initialXLim     % initial x-axis limits, used to reset the zoom
        initialYLim     % initial y-axis limits per axis (Nx2), used to reset the zoom
        timeFormatStr   % printf format + unit, e.g. '%.4f ms', for the info bar

        controlPanel    % uipanel at the top holding the control buttons
        waveformButtons % array of togglebutton uicontrols, one per axis
        zoomButton      % togglebutton uicontrol for zoom
        panButton       % togglebutton uicontrol for pan
        linkGradButton  % togglebutton uicontrol for gradient y-axis linking

        gradYLinked     % logical, whether Gx/Gy/Gz share one y-scale
        gradYListeners  % cell array of YLim PostSet listeners for Gx/Gy/Gz
        syncingGradYLim % re-entrancy guard while propagating a linked y-zoom

        mmbActive         % logical, true while a middle-button drag is in progress
        mmbStartPointPix  % [x y] figure CurrentPoint (pixels) at the previous motion event; advanced each frame
        mmbRefAxIdx       % index into obj.ax of the reference axis used for this drag
        mmbRefAxWidthPix  % pixel width of the reference axis at drag start
        mmbRefAxHeightPix % pixel height of the reference axis at drag start

        tFactor            % numeric time-unit scale factor (e.g. 1e3 for ms), converts plotted (scaled) times back to raw seconds
        axSnapX            % cell array (1xnumel(ax)), x (time) value of every plotted-line vertex in each axis, for snapping the guide/data-tip to actual waveform points
        axSnapLines        % cell array (1xnumel(ax)), the (few) line handles per axis
        axSnapLineOfVertex % cell array (1xnumel(ax)), index into axSnapLines{i} of the line owning each axSnapX entry
        axSnapLocalIdx     % cell array (1xnumel(ax)), index of each axSnapX entry within its own line's XData/YData
        hDataTipBox        % annotation textbox used as the manual hover data-tip popup

        infoPanel       % uipanel at the bottom showing the guide time
        hTextInfo       % text uicontrol inside infoPanel

    end

    properties (Constant = true, Hidden = true)

        % vertical margin (px)
        margin = 6;
        % lower vertical margin (px)
        my1 = 45;
        % left horizontal margin
        mx1 = 70;
        % right horizontal margin
        mx2 = 5;

        % height of the top control-button panel (px)
        controlPanelHeight = 26;
        % height of the bottom info panel (px)
        infoPanelHeight = 20;

        % indices into obj.ax of the Gx/Gy/Gz gradient axes
        gradAxIdx = [4 5 6];

        % gain for middle-button-drag vertical zoom: a full-axis-height
        % drag changes the time range width by a factor of 2^mmbZoomGain
        mmbZoomGain = 4;

        % pixel distance (in x, within the hovered axis) inside which a
        % nearby waveform point is considered "hovered" and shows the
        % data-tip popup
        dataTipPixelThresh = 15;

    end


    methods

        function obj = SeqPlot(seq, varargin)

            validTimeUnits = {'s','ms','us'};
            validLabel = mr.getSupportedLabels();
            persistent parser
            if isempty(parser)
                parser = inputParser;
                parser.FunctionName = 'plot';
                parser.addParamValue('showBlocks',false,@(x)(isnumeric(x) || islogical(x)));
                parser.addParamValue('timeRange',[0 inf],@(x)(isnumeric(x) && length(x)==2));
                parser.addParamValue('blockRange',[1 inf],@(x)(isnumeric(x) && length(x)==2));
                parser.addParamValue('timeDisp',validTimeUnits{1},...
                    @(x) any(validatestring(x,validTimeUnits)));
                parser.addParamValue('label',[]);%,@(x)(isstr(x)));%@(x) any(validatestring(x,validLabel))
                parser.addParamValue('hide',false);%,@(x)(isstr(x)));%@(x) any(validatestring(x,validLabel))
                parser.addParamValue('stacked',false);%,@(x)(isstr(x)));%@(x) any(validatestring(x,validLabel))
                parser.addParamValue('showGuides',true);%,@(x)(isstr(x)));%@(x) any(validatestring(x,validLabel))
                parser.addParamValue('showLimits',true,@(x)(isnumeric(x) || islogical(x)));
                parser.addParamValue('showSlew',false,@(x)(isnumeric(x) || islogical(x)));
                parser.addParamValue('extra',struct('t',{},'waveform',{},'label',{}));
            end
            parse(parser,varargin{:});
            opt = parser.Results;
            nExtra = numel(opt.extra);

            obj.stackedMode = logical(opt.stacked);

            if mr.aux.isOctave()
              if opt.stacked
                warning('Option stacked is not (yet) supported by Octave');
                opt.stacked=false;
              end
              if opt.showBlocks
                warning('Option stacked is not (yet) supported by Octave');
                opt.showBlocks=false;
              end
            end

            obj.f=figure;
            obj.hSeq=seq; % Sequence is a handle-class so copying is cheap...

            set(obj.f, 'Visible', 'off')

            % with 'showSlew' three more axes (SRx/SRy/SRz) are created;
            % the subplot grid shape is irrelevant (relayout() below
            % repositions everything), it only provides the axes
            showSlew = logical(opt.showSlew);
            nAxBase = 6 + 3*showSlew;
            nCols = nAxBase/3;
            if ~mr.aux.isOctave()
              obj.ax = gobjects(1,nAxBase);
            end
            for i=1:nAxBase
                obj.ax(i)=subplot(3,nCols,i);
            end
            % Re-order axes column-major (equals [1 3 5 2 4 6] for nAxBase==6)
            obj.ax=obj.ax(reshape(reshape(1:nAxBase,nCols,3).',1,[]));
            if showSlew
                obj.slewAxIdx = 7:9;
                % each SR axis sits directly below its gradient axis, so
                % the shared time axis stays vertically aligned
                obj.axColumns = {[1 2 3], [4 7 5 8 6 9]};
                obj.axStackOrder = [1 2 3 4 7 5 8 6 9];
            else
                obj.slewAxIdx = [];
                obj.axColumns = {[1 2 3], [4 5 6]};
                obj.axStackOrder = 1:6;
            end
            % user-supplied 'extra' waveforms each get their own axis,
            % appended after the base(+slew) axes and grouped into one more
            % grid column / the tail of the stacked order. This must happen
            % before hold/grid/linkaxes below so those (and the several
            % generic numel(obj.ax) loops further down) cover the extra
            % axes too; the axes' initial subplot position is irrelevant
            % since relayout() repositions everything explicitly.
            if nExtra > 0
                for i = 1:nExtra
                    obj.ax(nAxBase+i) = axes('Parent', obj.f);
                end
                obj.extraAxIdx = nAxBase+1 : nAxBase+nExtra;
                obj.axColumns{end+1} = obj.extraAxIdx;
                obj.axStackOrder = [obj.axStackOrder, obj.extraAxIdx];
            else
                obj.extraAxIdx = [];
            end
            arrayfun(@(x)hold(x,'on'),obj.ax);
            arrayfun(@(x)grid(x,'on'),obj.ax);
            % Link the x-axes now, while the axes are still empty. Calling
            % linkaxes on already-populated axes forces an expensive
            % limit-reconcile / render pass over every plotted point
            % (~0.4s extra for large sequences); doing it up front avoids
            % that. The real display range is applied with an explicit
            % xlim(dispRange) after all data has been plotted below.
            % linkaxes sets BOTH XLimMode and YLimMode to 'manual'; the
            % x-link needs the manual XLimMode, but YLimMode must be put
            % back to 'auto' so the y-axes still auto-scale to the data as
            % it is plotted (otherwise they stay frozen at the default
            % [0 1]). Per-axis y-limits are finalised explicitly further
            % below.
            linkaxes(obj.ax(:),'x')
            set(obj.ax, 'YLimMode', 'auto');
            obj.labels={'ADC/lbl/trig','RF mag (Hz)','RF/ADC ph (rad)','Gx (kHz/m)','Gy (kHz/m)','Gz (kHz/m)'};
            if showSlew
                obj.labels=[obj.labels {'SRx (kHz/m/ms)','SRy (kHz/m/ms)','SRz (kHz/m/ms)'}];
            end
            for i = 1:nExtra
                if isfield(opt.extra,'label') && ~isempty(opt.extra(i).label)
                    obj.labels{end+1} = opt.extra(i).label;
                else
                    obj.labels{end+1} = sprintf('extra %d', i);
                end
            end
            arrayfun(@(x)ylabel(obj.ax(x),obj.labels{x}),1:numel(obj.labels));
            if ~mr.aux.isOctave()
                % hide the per-axes interactive toolbar; the custom
                % control panel provides zoom/pan/show-hide instead
                arrayfun(@(x)set(x.Toolbar,'Visible','off'),obj.ax);
            end

            tFactorList = [1 1e3 1e6];
            tFactor = tFactorList(strcmp(opt.timeDisp,validTimeUnits));
            obj.tFactor = tFactor;
            obj.xLabelStr = ['t (' opt.timeDisp ')'];

            t0=0;
            label_defined=false;
            label_indexes_2plot=[];
            label_legend_2plot=[];
            for i=1:length(validLabel)
                label_store.(validLabel{i})=0;
                if ~isempty(opt.label) && ~isempty(strfind(upper(opt.label),validLabel{i}))
                    label_indexes_2plot=[label_indexes_2plot i];
                    label_legend_2plot=[label_legend_2plot; validLabel{i}];
                end
            end
            if ~isempty(label_indexes_2plot)
                if mr.aux.isOctave()
                    label_colors_2plot=turbo(length(label_indexes_2plot)+1); % need +1 because the ADC plot by itself also "eats up" one color
                else
                    label_colors_2plot=parula(length(label_indexes_2plot)+1); % need +1 because the ADC plot by itself also "eats up" one color
                end
                label_colors_2plot=[label_colors_2plot(end,:); label_colors_2plot(1:end-1,:)]; % we like these colors better ?
            end

            % time format
            switch opt.timeDisp
                case 'us'
                    timeFormat='%.1f';
                case 'ms'
                    timeFormat='%.4f';
                otherwise
                    timeFormat='%.7f';
            end
            obj.timeFormatStr = [timeFormat ' ' opt.timeDisp];

            % data cursor callback
            if ~mr.aux.isOctave()
              hDCM = datacursormode(obj.f);
              hDCM.UpdateFcn = @(src, event)DataTipHandler(obj,src,event);
            end

            % time/block range
            timeRange=opt.timeRange;
            blockEdges=[0 cumsum(seq.blockDurations)];
            if opt.blockRange(1)>1 && blockEdges(opt.blockRange(1))>timeRange(1)
                timeRange(1)=blockEdges(opt.blockRange(1));
            end
            if isfinite(opt.blockRange(2)) && opt.blockRange(2)<length(seq.blockDurations) && blockEdges(opt.blockRange(2)+1)<timeRange(2)
                timeRange(2)=blockEdges(opt.blockRange(2)+1);
            end
            % block timings
            blockEdgesInRange=blockEdges(logical((blockEdges>=timeRange(1)).*(blockEdges<=timeRange(2))));
            if strcmp(opt.timeDisp,'us') && ~mr.aux.isOctave()
                for i=1:numel(obj.ax)
                    xax=get(obj.ax(i),'XAxis');
                    xax.ExponentMode='manual';
                    xax.Exponent=0;
                end
            end
            if opt.showBlocks
                % show block edges in plots
                for i=1:numel(obj.ax)
                    xax=get(obj.ax(i),'XAxis');
                    xax.TickValues=unique(tFactor.*blockEdgesInRange);
                    set(obj.ax(i),'XTickLabelRotation',90);
                    %xax.MinorTickValues=tFactor.*blockEdgesInRange;
                    %set(obj.ax(i),'XMinorTick', 'on');
                    %set(obj.ax(i),'XMinorGrid', 'on');
                    %set(obj.ax(i),'GridColor',0.8*[1 1 1]);
                    %set(obj.ax(i),'MinorGridColor',0.6*[1 1 1]);
                    %set(obj.ax(i),'MinorGridLineStyle','-');
                end
            end
            %
            gradChannels={'gx','gy','gz'};

            % loop through blocks. Blocks entirely before the display
            % range are unpacked (getBlock) only when label plotting was
            % requested, since the label counters accumulate from the
            % first block onwards; once past the range end nothing can
            % contribute anymore, so the loop stops early.
            needLabels = ~isempty(label_indexes_2plot);
            for iB=1:length(seq.blockEvents)
                if t0 > timeRange(2)
                    break;
                end
                isValid = t0+seq.blockDurations(iB)>timeRange(1);
                if isValid || needLabels
                    block = seq.getBlock(iB);
                    % update the labels / counters even if we are below the display range
                    if isfield(block,'label') %current labels, works on the curent or next adc
                        for i=1:length(block.label)
                            if strcmp(block.label(i).type,'labelinc')
                                label_store.(block.label(i).label)=...
                                    label_store.(block.label(i).label)+block.label(i).value;
                            else
                                label_store.(block.label(i).label)=block.label(i).value;
                            end
                        end
                        label_defined=true;
                    end
                end
                if isValid
                    if isfield(block,'rotation')
                        % apply the rotation to the current block and restore the block structure
                        c=mr.rotate3D(block.rotation.rotQuaternion,block,'system',seq.sys);
                        for i=1:3
                            block.(gradChannels{i})=[];
                        end
                        for i=1:length(c)
                            if isstruct(c{i}) && isfield(c{i},'type') && isfield(c{i},'channel')
                                block.(['g' c{i}.channel])=c{i};
                            end
                        end
                    end
                    if isfield(block,'trig') && ~isempty(block.trig)
                        switch(block.trig.type)
                            case 'output'
                                % plot digital output triggers in the RF-TX pane
                                plot(tFactor*(t0+block.trig.delay),0,'diamond','Color',[0 0.5 0],'Parent',obj.ax(1));
                                plot(tFactor*(t0+block.trig.delay +[0 block.trig.duration]),[0 0],'-','Marker','.','Color',[0 0.5 0],'Parent',obj.ax(1));
                            case 'trigger'
                                plot(tFactor*(t0+block.trig.delay),0,'>b','Parent',obj.ax(1));
                                plot(tFactor*(t0+block.trig.delay),0,'.b','Parent',obj.ax(1));
                            %otherwise
                        end
                    end
                    if ~isempty(block.adc)
                        adc=block.adc;
                        t=adc.delay + ((0:adc.numSamples-1)'+0.5)*adc.dwell; % according to the information from Klaus Scheffler and indirectly from Siemens this is the present convention (the samples are shifted by 0.5 dwell)
                        plot(tFactor*(t0+t),zeros(size(t)),'rx','Parent',obj.ax(1));
                        if isempty(adc.phaseModulation)
                            adc.phaseModulation=0;
                        end
                        full_freqOffset=adc.freqOffset+adc.freqPPM*1e-6*seq.sys.gamma*seq.sys.B0;
                        full_phaseOffset=adc.phaseOffset+adc.phasePPM*1e-6*seq.sys.gamma*seq.sys.B0;
                        plot(tFactor*(t0+t), angle(exp(1i*(full_phaseOffset+adc.phaseModulation)).*exp(1i*2*pi*t*full_freqOffset)),'b.','MarkerSize',1,'Parent',obj.ax(3)); % plot ADC phase
                        % labels/counters/flags
                        if label_defined && ~isempty(label_indexes_2plot)
                            set(obj.ax(1),'ColorOrder',label_colors_2plot);
                            label_store_cell=struct2cell(label_store);
                            lbl_vals=[label_store_cell{label_indexes_2plot}];
                            t=t0+adc.delay + (adc.numSamples-1)/2*adc.dwell;
                            p=plot(tFactor*t,lbl_vals,'.','markersize',5,'Parent',obj.ax(1));
                            if ~isempty(label_legend_2plot)
                                legend(obj.ax(1),p,label_legend_2plot,'location','Northwest','AutoUpdate','off');
                                label_legend_2plot=[];
                            end
                        end
                    end
                    if ~isempty(block.rf)
                        rf=block.rf;
                        [tc,ic,fi]=mr.calcRfCenter(rf);
                        if fi==0
                            sc=rf.signal(ic);
                        else
                            sc=rf.signal(ic)*(1-abs(fi))+rf.signal(ic+sign(fi))*abs(fi);
                        end
                        if max(abs(diff(rf.t)-rf.t(2)+rf.t(1)))<1e-9 && length(rf.t)>100
                            % homogeneous sampling and long pulses -- use lower time resolution for better display and performance
                            dt=rf.t(2)-rf.t(1);
                            st=max(1,round(seq.sys.gradRasterTime/dt));
                            t=rf.t(1:st:end);
                            s=rf.signal(1:st:end);
                            % always include the last point for the accurate display
                            if (t(end)~=rf.t(end))
                                t(end+1)=rf.t(end);
                                s(end+1)=rf.signal(end);
                            end
                        else
                            t=rf.t;
                            s=rf.signal;
                        end
                        sreal=max(abs(imag(s)))/max(abs(real(s)))<1e-6; %all(isreal(s));
                        full_freqOffset=rf.freqOffset+rf.freqPPM*1e-6*seq.sys.gamma*seq.sys.B0;
                        full_phaseOffset=rf.phaseOffset+rf.phasePPM*1e-6*seq.sys.gamma*seq.sys.B0;
                        % If off-resonant and rectangular (2 samples), interpolate the pulse
                        if (length(s) == 2) && (full_freqOffset ~= 0)
                            numInterp = min(int32(abs(full_freqOffset)), 256);
                            t = linspace(t(1), t(end), numInterp)';
                            s = linspace(s(1), s(end), numInterp)';
                        end
                        if abs(s(1))~=0 % fix strangely looking phase / amplitude in the beginning
                            s=[0; s];
                            t=[t(1); t];
                            %ic=ic+1;
                        end
                        if abs(s(end))~=0 % fix strangely looking phase / amplitude at the end
                            s=[s; 0];
                            t=[t; t(end)];
                        end

                        if (sreal)
                            plot(tFactor*(t0+t+rf.delay),  real(s),'Parent',obj.ax(2));
                            plot(tFactor*(t0+t+rf.delay),  angle(s.*sign(real(s))*exp(1i*full_phaseOffset).*exp(1i*2*pi*t    *full_freqOffset)), tFactor*(t0+tc+rf.delay), angle(sc*exp(1i*full_phaseOffset).*exp(1i*2*pi*tc*full_freqOffset)),'xb', 'Parent',obj.ax(3));
                        else
                            plot(tFactor*(t0+t+rf.delay),  abs(s),'Parent',obj.ax(2));
                            plot(tFactor*(t0+t+rf.delay),  angle(s*exp(1i*full_phaseOffset).*exp(1i*2*pi*t    *full_freqOffset)), tFactor*(t0+tc+rf.delay), angle(sc*exp(1i*full_phaseOffset).*exp(1i*2*pi*tc*full_freqOffset)),'xb', 'Parent',obj.ax(3));
                        end
                    end
                    for j=1:length(gradChannels)
                        grad=block.(gradChannels{j});
                        if ~isempty(grad)
                            if strcmp(grad.type,'grad')
                                % we extend the shape by adding the first
                                % and the last points in an effort of
                                % making the display a bit less confusing...
                                %t=grad.delay + [0; grad.t + (grad.t(2)-grad.t(1))/2; grad.t(end) + grad.t(2)-grad.t(1)];
                                t= grad.delay+[0; grad.tt; grad.shape_dur];
                                waveform=1e-3* [grad.first; grad.waveform; grad.last];
                            else
                                t=cumsum([0 grad.delay grad.riseTime grad.flatTime grad.fallTime]);
                                waveform=1e-3*grad.amplitude*[0 0 1 1 0];
                            end
                            plot(tFactor*(t0+t),waveform,'Parent',obj.ax(3+j));
                            if showSlew && numel(t) > 1
                                % slew rate between consecutive waveform
                                % vertices, plotted as a stairstep since
                                % it is piecewise-constant between them;
                                % zero-duration segments (e.g. trapezoids
                                % with delay==0 or flatTime==0) are
                                % dropped to avoid 0/0. waveform is in
                                % kHz/m and t in s, so the extra 1e-3
                                % yields kHz/m/ms. The last value is
                                % repeated so the final step spans to the
                                % end of the event.
                                tv=t(:); dt=diff(tv); dw=diff(waveform(:));
                                keep=dt>0;
                                if any(keep)
                                    sr=1e-3*dw(keep)./dt(keep);
                                    ts=tv([keep; true]);
                                    stairs(tFactor*(t0+ts),[sr; sr(end)],'Parent',obj.ax(6+j));
                                end
                            end
                        end
                    end
                end
                t0=t0+seq.blockDurations(iB);%mr.calcDuration(block);
            end

            % plot the user-supplied 'extra' waveforms, one axis per
            % struct-array element; t/waveform may each be a plain vector
            % (single trace) or a cell array of vectors (multiple traces
            % sharing that axis), with an optional 'name' cell array of
            % legend entries. t is expected in raw seconds, like every
            % other time value plotted above, hence the same tFactor scale.
            for i = 1:nExtra
                ax = obj.ax(obj.extraAxIdx(i));
                tCell = opt.extra(i).t;        if ~iscell(tCell), tCell = {tCell}; end
                wCell = opt.extra(i).waveform; if ~iscell(wCell), wCell = {wCell}; end
                hLines = gobjects(1, numel(tCell));
                for k = 1:numel(tCell)
                    hLines(k) = plot(tFactor*tCell{k}, wCell{k}, 'Parent', ax);
                end
                if isfield(opt.extra,'name') && ~isempty(opt.extra(i).name)
                    legend(ax, hLines, opt.extra(i).name, 'AutoUpdate','off');
                end
            end

            % Cache, per axis, the x (time) value of every vertex of
            % every plotted line, so findHoverPoint can snap the guides/
            % data-tip to actual waveform time points instead of an
            % arbitrary cursor position. To keep this cheap even for
            % sequences with hundreds of thousands of plotted samples,
            % everything is stored as flat numeric arrays (never a
            % graphics-handle array per vertex): axSnapX is the
            % concatenated x-values, axSnapLineOfVertex maps each vertex
            % to its line's index within the small per-axis axSnapLines
            % handle list, and axSnapLocalIdx is the vertex's index
            % within its own line's XData/YData. Values are collected in
            % cells and concatenated once (O(total vertices)) rather than
            % grown incrementally.
            if ~mr.aux.isOctave()
                obj.axSnapX = cell(1, numel(obj.ax));
                obj.axSnapLines = cell(1, numel(obj.ax));
                obj.axSnapLineOfVertex = cell(1, numel(obj.ax));
                obj.axSnapLocalIdx = cell(1, numel(obj.ax));
                for i = 1:numel(obj.ax)
                    % 'stair' covers the slew-rate stairstep plots, which
                    % are Stair (not Line) objects
                    lines = findobj(obj.ax(i), 'Type', 'line', '-or', 'Type', 'stair');
                    nL = numel(lines);
                    xdc = cell(1, nL);
                    lov = cell(1, nL);
                    lic = cell(1, nL);
                    for k = 1:nL
                        xd = get(lines(k), 'XData');
                        xdc{k} = xd;
                        lov{k} = repmat(k, 1, numel(xd));
                        lic{k} = 1:numel(xd);
                    end
                    obj.axSnapX{i} = [xdc{:}];
                    obj.axSnapLineOfVertex{i} = [lov{:}];
                    obj.axSnapLocalIdx{i} = [lic{:}];
                    obj.axSnapLines{i} = lines;
                end
            end

            % Set axis limits and zoom properties. The x-axes were
            % already linked (above, while empty); this xlim call applies
            % the actual display range and propagates it across the link.
            dispRange = tFactor*[timeRange(1) min(timeRange(2),t0)];
            obj.initialXLim = dispRange;
            arrayfun(@(x)xlim(x,dispRange),obj.ax);
            if ~mr.aux.isOctave()
              h = zoom(obj.f);
              setAxesZoomMotion(h,obj.ax(1),'horizontal');
              p = pan(obj.f);
              p.Motion = 'horizontal';
            end
            if ~mr.aux.isOctave()
                set(obj.f, 'WindowButtonDownFcn',   @obj.onMmbDown);
                set(obj.f, 'WindowButtonMotionFcn', @obj.onMmbDrag);
                set(obj.f, 'WindowButtonUpFcn',     @obj.onMmbUp);
                % floating hover data-tip popup, manually driven from
                % onMmbDrag since the custom callbacks above disable
                % MATLAB's built-in default interactivity (and with it
                % the automatic hover data tip) figure-wide
                obj.hDataTipBox = annotation(obj.f, 'textbox', [0 0 0.01 0.01], 'Visible', 'off');
                set(obj.hDataTipBox, 'Units', 'pixels', 'BackgroundColor', [1 1 0.85], ...
                    'EdgeColor', [0.4 0.4 0.4], 'FitBoxToText', 'on', 'Interpreter', 'tex', ...
                    'FontSize', 8, 'Margin', 3, 'HitTest', 'off', 'PickableParts', 'none');
            end
            obj.mmbActive = false;
            % The y-axes are in 'auto' mode but their limits are computed
            % lazily (only at render time); force that computation now so
            % the padding/read-back below sees the real data ranges rather
            % than the default [0 1]. (Previously the linkaxes call that
            % ran here after filling triggered this implicitly.)
            drawnow;
            % manually fix the phase vertical scale to +- pi
            ylim(obj.ax(3),[-pi pi]);
            % make Y-axes little bit less tight
            arrayfun(@(x) ylim(x, ylim(x) + 0.03*[-1 1]*sum(ylim(x).*[-1 1])), obj.ax(2:end));

            obj.initialYLim = zeros(numel(obj.ax), 2);
            for ii = 1:numel(obj.ax)
                obj.initialYLim(ii,:) = ylim(obj.ax(ii));
            end

            % plot the system limits as dashed red reference lines: maxB1
            % on the RF magnitude axis and maxGrad on the Gx/Gy/Gz axes.
            % These are created only now, after the y-limits have been
            % fixed (YLimMode is 'manual' at this point), so that the
            % reference lines do not expand the axes to the limit values.
            % They are drawn at twice the default line width and half
            % opacity.
            if opt.showLimits
                if mr.aux.isOctave()
                    warning('Option showLimits is not (yet) supported by Octave');
                else
                    limLineWidth = 2*get(groot,'DefaultLineLineWidth'); % twice the usual waveform line width
                    maxB1Plot   = seq.sys.maxB1;        % Hz, matches the RF mag axis
                    maxGradPlot = 1e-3*seq.sys.maxGrad; % Hz/m -> kHz/m, matches the gradient axes
                    % RF magnitude limit (axis 2)
                    yline(obj.ax(2),  maxB1Plot, '--', 'Color',[1 0 0], 'Alpha',0.5, 'LineWidth',limLineWidth);
                    yline(obj.ax(2), -maxB1Plot, '--', 'Color',[1 0 0], 'Alpha',0.5, 'LineWidth',limLineWidth);
                    % gradient limits (axes 4,5,6 = Gx,Gy,Gz)
                    for j=1:3
                        yline(obj.ax(3+j),  maxGradPlot, '--', 'Color',[1 0 0], 'Alpha',0.5, 'LineWidth',limLineWidth);
                        yline(obj.ax(3+j), -maxGradPlot, '--', 'Color',[1 0 0], 'Alpha',0.5, 'LineWidth',limLineWidth);
                    end
                    % slew-rate limits (axes 7,8,9 = SRx,SRy,SRz), if present
                    if ~isempty(obj.slewAxIdx)
                        maxSlewPlot = 1e-6*seq.sys.maxSlew; % Hz/m/s -> kHz/m/ms, matches the slew axes
                        for idx=obj.slewAxIdx
                            yline(obj.ax(idx),  maxSlewPlot, '--', 'Color',[1 0 0], 'Alpha',0.5, 'LineWidth',limLineWidth);
                            yline(obj.ax(idx), -maxSlewPlot, '--', 'Color',[1 0 0], 'Alpha',0.5, 'LineWidth',limLineWidth);
                        end
                    end
                end
            end

            % Gx/Gy/Gz start out independently scaled (each to its own
            % initial range); the "Link Grad Y" button switches them to a
            % shared scale. The listeners propagate interactive y-zooming
            % between the three while linked, regardless of mode changes.
            obj.gradYLinked = false;
            obj.syncingGradYLim = false;
            if ~mr.aux.isOctave()
                obj.gradYListeners = cell(1, numel(obj.gradAxIdx));
                for k = 1:numel(obj.gradAxIdx)
                    idx = obj.gradAxIdx(k);
                    obj.gradYListeners{k} = addlistener(obj.ax(idx), 'YLim', 'PostSet', ...
                        @(~,~) obj.onGradYLimChanged(idx));
                end
            end

            obj.axVisible = true(1, numel(obj.ax));

            if opt.showGuides
              if mr.aux.isOctave()
                warning('Option showGuides is not implemented in Octave');
              else
                % add vertical lines and make them follow the cursor
                % x-position
                for ii = 1:numel(obj.ax)
                    obj.vLines(ii) = xline(obj.ax(ii), 0, 'r--');
                end

                % info bar at the bottom showing the time at the guide position
                obj.infoPanel = uipanel('Parent', obj.f, 'Units', 'pixels', ...
                    'Position', [0 0 obj.f.Position(3) obj.infoPanelHeight]);
                obj.hTextInfo = uicontrol( ...
                    'Style',            'text', ...
                    'Parent',           obj.infoPanel, ...
                    'Units',            'pixels', ...
                    'Position',         [10 0 300 obj.infoPanelHeight], ...
                    'HorizontalAlignment', 'left', ...
                    'FontUnits',        'normalized', ...
                    'FontSize',         0.8, ...
                    'String',           sprintf(['t = ' obj.timeFormatStr], 0));
              end
            end

            % axis positions are recomputed on every resize and whenever a
            % waveform is shown/hidden, for both the stacked and the grid
            % layout
            set(obj.f, 'ResizeFcn', @obj.relayout)
            obj.createControlPanel();
            obj.relayout();

            % Axes created via axes() (the 'extra' axes) do not pick up the
            % same automatic tick-label font size as axes created via
            % subplot() -- MATLAB's 'auto' FontSizeMode evidently resolves
            % differently depending on how the axes was created, not just
            % its final size, so the extra axes' ticks otherwise render
            % visibly smaller than the built-in ones. Force them (both the
            % axes-level font used for labels/title and the tick-label
            % fonts) to match a base axis explicitly. drawnow first so the
            % reference axis' own 'auto' value has actually been resolved
            % (auto-computed axis properties are otherwise only settled at
            % render time -- see the drawnow before the ylim padding
            % further above).
            if ~isempty(obj.extraAxIdx) && ~mr.aux.isOctave()
                drawnow;
                refAx = obj.ax(1);
                for idx = obj.extraAxIdx
                    set(obj.ax(idx), 'FontSize', refAx.FontSize);
                    obj.ax(idx).XAxis.FontSize = refAx.XAxis.FontSize;
                    obj.ax(idx).YAxis.FontSize = refAx.YAxis.FontSize;
                end
            end

            if ~opt.hide
                set(obj.f, 'Visible', 'on')
            end

            % do not assign to 'ans' when called without assigned variable
            if nargout == 0
                clear obj
            end
        end

        function relayout(obj, ~, ~)
            % relayout()
            %   Is called whenever the figure shape changes, and whenever
            %   a waveform is shown/hidden via the control panel.
            %   Repositions the control/info panels and positions all
            %   visible axes so that they fill the available space,
            %   collapsing any hidden ones. In 'stacked' mode all axes
            %   share one column (in axStackOrder); otherwise they are
            %   arranged in the two columns given by axColumns
            %   (ADC/lbl/trig, RF mag, RF/ADC ph | Gx, Gy, Gz, with each
            %   slew-rate axis interleaved directly below its gradient
            %   when 'showSlew' is active).

            width  = obj.f.Position(3);
            height = obj.f.Position(4);

            if ~isempty(obj.controlPanel) && isvalid(obj.controlPanel)
                set(obj.controlPanel, 'Position', [0 height-obj.controlPanelHeight width obj.controlPanelHeight]);
            end
            if ~isempty(obj.infoPanel) && isvalid(obj.infoPanel)
                set(obj.infoPanel, 'Position', [0 0 width obj.infoPanelHeight]);
                bottomExtra = obj.infoPanelHeight;
            else
                bottomExtra = 0;
            end

            if obj.stackedMode
                columns = {obj.axStackOrder};
            else
                columns = obj.axColumns;
            end

            colWidth = width / numel(columns);
            availHeight = height - obj.controlPanelHeight - obj.my1 - bottomExtra;

            for c = 1:numel(columns)
                colIdx = columns{c};
                visIdx = colIdx(obj.axVisible(colIdx));
                nVis = numel(visIdx);
                if nVis == 0
                    continue
                end
                x0 = (c-1)*colWidth + obj.mx1;
                axWidth = colWidth - obj.mx1 - obj.mx2;
                axHeight = (availHeight - (nVis-1)*obj.margin) / nVis;
                for k = 1:nVis
                    idx = visIdx(k);
                    y0 = height - obj.controlPanelHeight - k*axHeight - (k-1)*obj.margin;
                    set(obj.ax(idx), 'Units', 'pixels', 'Position', [x0 y0 axWidth axHeight]);
                    if k ~= nVis
                        set(obj.ax(idx), 'XTickLabel', {});
                        obj.ax(idx).XLabel.String = '';
                    else
                        set(obj.ax(idx), 'XTickLabelMode', 'auto');
                        obj.ax(idx).XLabel.String = obj.xLabelStr;
                    end
                end
            end
        end

        function createControlPanel(obj)
            % createControlPanel()
            %   Builds a row of regular push/toggle buttons at the top of
            %   the figure for zoom/pan, per-waveform show/hide, and a
            %   reset-zoom button. Plain uicontrol buttons (rather than a
            %   MATLAB toolbar) are used so the full waveform name fits
            %   as text on the button instead of a tiny icon.

            width = obj.f.Position(3);
            height = obj.f.Position(4);
            obj.controlPanel = uipanel('Parent', obj.f, 'Units', 'pixels', ...
                'Position', [0 height-obj.controlPanelHeight width obj.controlPanelHeight], ...
                'BorderType', 'none');

            x = 4;
            h = obj.controlPanelHeight - 6;
            y = 3;
            gap = 4;

            [obj.zoomButton, x] = obj.addButton('Zoom', x, y, h, gap, @(src,~) obj.onToggleZoom(src));
            [obj.panButton, x]  = obj.addButton('Pan',  x, y, h, gap, @(src,~) obj.onTogglePan(src));
            [~, x] = obj.addButton(char(8962), x, y, h, gap, @(src,~) obj.onResetView(src), 'pushbutton');

            x = x + 3*gap;
            obj.waveformButtons = gobjects(1, numel(obj.labels));
            for i = 1:numel(obj.labels)
                [obj.waveformButtons(i), x] = obj.addButton(obj.stripBrackets(obj.labels{i}), x, y, h, gap, ...
                    @(src,~) obj.onToggleWaveform(i, src));
                set(obj.waveformButtons(i), 'Value', 1);
            end

            x = x + 3*gap;
            [obj.linkGradButton, x] = obj.addButton('Link Grad Y', x, y, h, gap, ...
                @(src,~) obj.onToggleGradYLink(src));
            set(obj.linkGradButton, 'Value', obj.gradYLinked);
        end

        function str = stripBrackets(~, str)
            % stripBrackets(str)
            %   Removes any '(...)' groups (e.g. unit suffixes like
            %   '(kHz/m)') and trailing whitespace, so button labels stay
            %   short while the y-axis labels keep the full text.

            str = regexprep(str, '\([^)]*\)', '');
            str = regexprep(str, '\s+$', '');
        end

        function [btn, xNext] = addButton(obj, str, x, y, h, gap, callback, style)
            % addButton(str, x, y, h, gap, callback, style)
            %   Creates a uicontrol button (togglebutton by default) sized
            %   to fit str, placed at (x,y) in obj.controlPanel, and
            %   returns the x-position for the next button.

            if nargin < 8
                style = 'togglebutton';
            end
            w = max(40, 7*numel(str) + 16);
            btn = uicontrol('Parent', obj.controlPanel, 'Style', style, ...
                'String', str, 'Units', 'pixels', 'Position', [x y w h], ...
                'Callback', callback);
            xNext = x + w + gap;
        end

        function onToggleWaveform(obj, idx, src)
            % onToggleWaveform(idx, src)
            %   Callback for the per-waveform show/hide buttons. Shows/
            %   hides axis idx and triggers a relayout.

            tf = logical(src.Value);
            obj.axVisible(idx) = tf;
            obj.setAxisVisible(idx, tf);
            obj.relayout();
            obj.removeFocus(src);
        end

        function removeFocus(~, src)
            % removeFocus(src)
            %   Clears the keyboard-focus highlight ring left on a button
            %   after a click, by briefly disabling and re-enabling it
            %   (a common uicontrol trick). Without this the focus ring
            %   competes visually with the toggle's own pressed/released
            %   look, making it hard to tell whether a button is toggled.

            set(src, 'Enable', 'off');
            drawnow;
            set(src, 'Enable', 'on');
        end

        function setAxisVisible(obj, idx, tf)
            % setAxisVisible(idx, tf)
            %   Shows/hides axis idx together with its plotted content
            %   (axes 'Visible' alone does not affect line/legend
            %   objects).

            if tf, onoff = 'on'; else, onoff = 'off'; end
            set(obj.ax(idx), 'Visible', onoff);
            set(allchild(obj.ax(idx)), 'Visible', onoff);
            lgd = get(obj.ax(idx), 'Legend');
            if ~isempty(lgd) && isvalid(lgd)
                set(lgd, 'Visible', onoff);
            end
        end

        function onResetView(obj, src)
            % onResetView()
            %   Callback for the reset (home) button. Restores the x-axis
            %   limits to the initial range (axes are linked on x, so
            %   setting one propagates to all of them) and restores the
            %   y-axis limits: each axis to its own initial range, except
            %   Gx/Gy/Gz which reset to the shared common range if the
            %   "Link Grad Y" mode is currently active.

            xlim(obj.ax(1), obj.initialXLim);
            obj.syncingGradYLim = true;
            for ii = 1:numel(obj.ax)
                if obj.gradYLinked && any(ii == obj.gradAxIdx)
                    ylim(obj.ax(ii), obj.commonGradYLim());
                else
                    ylim(obj.ax(ii), obj.initialYLim(ii,:));
                end
            end
            obj.syncingGradYLim = false;
            if nargin > 1
                obj.removeFocus(src);
            end
        end

        function lim = commonGradYLim(obj)
            % commonGradYLim()
            %   The shared y-range used when Gx/Gy/Gz are linked: the
            %   widest span across their individual initial ranges, so
            %   nothing gets clipped once they share one scale.

            gradRows = obj.initialYLim(obj.gradAxIdx, :);
            lim = [min(gradRows(:,1)), max(gradRows(:,2))];
        end

        function onToggleGradYLink(obj, src)
            % onToggleGradYLink(src)
            %   Callback for the "Link Grad Y" button. When switched on,
            %   Gx/Gy/Gz immediately snap to one shared y-range (the
            %   widest of their individual initial ranges) and further
            %   y-zooming on any of them is mirrored on the other two via
            %   onGradYLimChanged. When switched off, each snaps back to
            %   its own initial range and zooming becomes independent
            %   again.

            obj.gradYLinked = logical(src.Value);
            obj.syncingGradYLim = true;
            if obj.gradYLinked
                commonLim = obj.commonGradYLim();
                for idx = obj.gradAxIdx
                    ylim(obj.ax(idx), commonLim);
                end
            else
                for idx = obj.gradAxIdx
                    ylim(obj.ax(idx), obj.initialYLim(idx,:));
                end
            end
            obj.syncingGradYLim = false;
            obj.removeFocus(src);
        end

        function onGradYLimChanged(obj, changedIdx)
            % onGradYLimChanged(changedIdx)
            %   YLim PostSet listener callback for one of Gx/Gy/Gz. While
            %   linked, mirrors the new range onto the other two axes; the
            %   syncingGradYLim guard prevents this from re-triggering
            %   itself as it sets those axes' YLim in turn.

            if ~obj.gradYLinked || obj.syncingGradYLim
                return;
            end
            newLim = ylim(obj.ax(changedIdx));
            obj.syncingGradYLim = true;
            for idx = obj.gradAxIdx(obj.gradAxIdx ~= changedIdx)
                ylim(obj.ax(idx), newLim);
            end
            obj.syncingGradYLim = false;
        end

        function onToggleZoom(obj, src)
            % onToggleZoom(src)
            %   Callback for the Zoom button. Zoom and pan are mutually
            %   exclusive, so enabling one releases the other's button.

            if logical(src.Value)
                zoom(obj.f, 'on');
                set(obj.panButton, 'Value', 0);
                % the mode takes over the mouse callbacks, so the tip
                % cannot update and would sit frozen -- hide it
                obj.hideDataTip();
            else
                zoom(obj.f, 'off');
            end
            obj.removeFocus(src);
        end

        function onTogglePan(obj, src)
            % onTogglePan(src)
            %   Callback for the Pan button. See onToggleZoom for the
            %   mutual-exclusion note.

            if logical(src.Value)
                pan(obj.f, 'on');
                set(obj.zoomButton, 'Value', 0);
                % see onToggleZoom for the hide rationale
                obj.hideDataTip();
            else
                pan(obj.f, 'off');
            end
            obj.removeFocus(src);
        end

        function onMmbDown(obj, ~, ~)
            % onMmbDown()
            %   WindowButtonDownFcn for the middle-mouse-drag time
            %   pan/zoom gesture (see onMmbDrag). Middle-click is
            %   identified via SelectionType 'extend', MATLAB's standard
            %   proxy for the middle button (also produced by
            %   shift+left-click, which is accepted as an alias). Records
            %   the mouse position and the pixel size of a reference axis
            %   (the first visible one), used by onMmbDrag to apply an
            %   incremental pan/zoom on every motion event.

            if ~strcmp(obj.f.SelectionType, 'extend')
                return;
            end
            refIdx = find(obj.axVisible, 1);
            if isempty(refIdx)
                return;
            end
            obj.mmbRefAxIdx = refIdx;
            obj.mmbStartPointPix = obj.f.CurrentPoint;
            pos = get(obj.ax(refIdx), 'Position'); % pixels, per relayout
            obj.mmbRefAxWidthPix = pos(3);
            obj.mmbRefAxHeightPix = pos(4);
            obj.mmbActive = true;
            % the hover data-tip is not updated while dragging (see
            % onMmbDrag), so hide it rather than leaving it frozen
            obj.hideDataTip();
        end

        function onMmbDrag(obj, ~, ~)
            % onMmbDrag()
            %   WindowButtonMotionFcn, called on every mouse move over
            %   the figure (not just while dragging). While no drag is
            %   active, snaps the vertical guide lines / info-bar and the
            %   hover data-tip popup to the nearest actual waveform time
            %   point under the cursor (via findHoverPoint) -- this
            %   class's own custom WindowButtonDownFcn/MotionFcn/UpFcn
            %   (needed for the middle-button drag gesture below) disable
            %   MATLAB's built-in default interactivity figure-wide,
            %   including the hover data tip that used to drive both of
            %   those via DataTipHandler, so both are reimplemented here
            %   directly instead of relying on datacursormode. During a
            %   drag this hover work is skipped entirely: its result is
            %   not needed then, and findHoverPoint's scan over all
            %   plotted vertices is exactly what would make the gesture
            %   sluggish on large sequences.
            %
            %   If a drag started in onMmbDown, instead pans/zooms
            %   the time range incrementally: each motion event applies
            %   the pixel delta since the previous event to the current
            %   range. Horizontal motion pans so that the plotted content
            %   follows the cursor (the standard grab-and-drag
            %   convention, matching MATLAB's own built-in pan tool);
            %   vertical motion zooms the range in/out (drag up = zoom
            %   in) around the current center of the axis, so that
            %   whatever is centered stays centered regardless of how the
            %   range has already been panned or zoomed. Because the pan
            %   step is scaled by the current width, a given pixel of
            %   cursor motion always maps to the same on-screen distance,
            %   however far the gesture has already zoomed. Only xlim is
            %   ever touched, so y-axis scales are never affected. Since
            %   all axes are x-linked via linkaxes, setting xlim on the
            %   reference axis propagates to the rest.

            if ~obj.mmbActive
                [hoveredIdx, snappedT, targetLine, localIdx, distPix] = obj.findHoverPoint();
                if ~isempty(hoveredIdx)
                    obj.updateGuides(snappedT);
                end
                obj.updateDataTipFromCursor(hoveredIdx, targetLine, localIdx, distPix);
                return;
            end
            cp = obj.f.CurrentPoint;
            dxPix = cp(1) - obj.mmbStartPointPix(1);
            dyPix = cp(2) - obj.mmbStartPointPix(2);
            obj.mmbStartPointPix = cp; % advance reference for next event

            curXLim = xlim(obj.ax(obj.mmbRefAxIdx));
            curWidth = diff(curXLim);
            curCenter = mean(curXLim);

            factor = 2^(dyPix / obj.mmbRefAxHeightPix * obj.mmbZoomGain);
            newWidth = curWidth / factor;
            minWidth = 1e-4 * diff(obj.initialXLim);
            if newWidth < minWidth
                newWidth = minWidth;
            end

            % Zoom about the current center, then pan by this frame's
            % horizontal cursor delta (scaled by the current width).
            panOffset = -dxPix / obj.mmbRefAxWidthPix * newWidth;
            newCenter = curCenter + panOffset;

            newXLim = newCenter + newWidth/2*[-1 1];
            xlim(obj.ax(obj.mmbRefAxIdx), newXLim);
        end

        function onMmbUp(obj, ~, ~)
            % onMmbUp()
            %   WindowButtonUpFcn that ends the middle-mouse-drag
            %   gesture. Unconditional reset, safe to call even if a
            %   drag was never active.

            obj.mmbActive = false;
        end

        function out=DataTipHandler(obj, src, event)
            if ~isa(event,'matlab.graphics.internal.DataTipEvent') || ...
               ~isprop(event, 'Position') || length(event.Position)<2 || ...
               ~isprop(event, 'Target')
                out=[];
                return;
            end
            ax=src.Host.Parent;
            t=event.Position(1);
            out = obj.buildTipLines(ax, event.Target, t, event.Position(2));

            % we need to delay the call of the update, otherwise the plot
            % object generates an exception; the timer deletes itself once
            % it has fired (timer objects are never garbage-collected)
            tmr=timer('StartDelay',0,'TimerFcn',@(~,~)updateGuides(obj,t), ...
                'StopFcn',@(tmrObj,~)delete(tmrObj));
            tmr.start();
        end

        function out = buildTipLines(obj, ax, target, t, yValue)
            % buildTipLines(ax, target, t, yValue)
            %   Builds the tex-formatted data-tip line cell array (time,
            %   Y value, and block/event id) for a point at time t /
            %   value yValue on graphics object target within axis ax.
            %   Shared by DataTipHandler (MATLAB's built-in hover data
            %   tip, unreachable in practice since the middle-drag
            %   gesture's custom WindowButton*Fcn callbacks disable
            %   default interactivity figure-wide -- kept for
            %   compatibility should that ever change) and
            %   updateDataTipFromCursor (this class's own manual
            %   hover-tip renderer, driven from onMmbDrag).

            % user-supplied 'extra' axes have no corresponding seq block
            % data to look up; show just the time/Y value
            axIdx = find(obj.ax == ax, 1);
            if ~isempty(obj.extraAxIdx) && ismember(axIdx, obj.extraAxIdx)
                out = {['\bf\color{blue}t:\rm\color{black}' sprintf(obj.timeFormatStr,t)],...
                       ['\bf\color{blue}Y:\rm\color{black}' num2str(yValue)]};
                return;
            end

            % get the relevant target from the y-axes title
            at=lower(ax.YLabel.String);
            if strcmp(at(1:3),'adc') || ...
               (strcmp(at(1:6),'rf/adc') && strcmp(target.LineStyle,'none') && strcmp(target.Marker,'.')) % we need to check whether we are dealing with the ADC phase, which is also shown in the same panel as the RF
                field='adc';
            elseif strcmp(at(1:2),'sr')
                % slew-rate axes: the data belongs to the gradient event
                % of the corresponding channel (srx -> gx etc.)
                field=['g' at(3)];
            else
                field=at(1:2);
            end
            % create the custom data tip as tex-formatted cell array of lines
            t0=t;
            if isa(target,'matlab.graphics.chart.primitive.Line') || ...
               isa(target,'matlab.graphics.chart.primitive.Stair')
                % for trapezoid gradients (and their slew-rate stairs)
                % the last point may belong to the next block
                t0=target.XData(1);
            end
            iB=obj.hSeq.findBlockByTime(t0/obj.tFactor);
            rb=obj.hSeq.getRawBlockContentIDs(iB);
            out={['\bf\color{blue}t:\rm\color{black}' sprintf(obj.timeFormatStr,t)],...
                 ['\bf\color{blue}Y:\rm\color{black}' num2str(yValue)],...
                 ''};
            if isempty(rb.(field))
                out{3}=['\bf\color{blue}blk:\rm\color{black}' num2str(iB)];
                % we could add handling of the trigger/label data tips here
                % specifically for the adc panel but it would imply a
                % substantial performance hit because we'd have to unpack
                % extensions, etc...
            else
                try
                    switch field(1)
                        case 'a'
                            name = obj.hSeq.adcID2NameMap(rb.(field));
                        case 'r'
                            name = obj.hSeq.rfID2NameMap(rb.(field));
                        otherwise
                            name = obj.hSeq.gradID2NameMap(rb.(field));
                    end
                    out{3}=['\bf\color{blue}blk:\rm\color{black}' num2str(iB) ' \bf\color{blue}' field '\_id:\rm\color{black}' num2str(rb.(field)) ' ''\bf\color{darkGreen}' name '\rm\color{black}'''];
                catch
                    out{3}=['\bf\color{blue}blk:\rm\color{black}' num2str(iB) ' \bf\color{blue}' field '\_id:\rm\color{black}' num2str(rb.(field))];
                end
            end
        end

        function updateGuides(obj, tPos)
            % updateGuides(tPos)
            %   updates the time-position for all vertical line objects in
            %   all axes, and the time shown in the bottom info bar

            for ii = 1:numel(obj.vLines)
                set(obj.vLines(ii), 'Value', tPos);
            end
            if ~isempty(obj.hTextInfo) && isvalid(obj.hTextInfo)
                obj.hTextInfo.String = sprintf(['t = ' obj.timeFormatStr], tPos);
            end
        end

        function [hoveredIdx, snappedT, targetLine, localIdx, distPix] = findHoverPoint(obj)
            % findHoverPoint()
            %   Locates the visible axis (if any) the cursor currently
            %   sits over, and within it the nearest actual waveform
            %   vertex to the cursor's x (time) position, using the
            %   axSnapX/axSnapLines/axSnapLineOfVertex/axSnapLocalIdx
            %   caches built at
            %   construction. Returns hoveredIdx=[] if the cursor is not
            %   over any visible axis. targetLine/localIdx are only
            %   populated when that axis has at least one plotted vertex
            %   to snap to; distPix is the pixel distance (in x) from the
            %   cursor to the snapped vertex, Inf if there was none to
            %   snap to.

            hoveredIdx = [];
            snappedT = [];
            targetLine = gobjects(0);
            localIdx = [];
            distPix = Inf;

            cp = obj.f.CurrentPoint;
            for i = find(obj.axVisible)
                pos = get(obj.ax(i), 'Position');
                if cp(1) < pos(1) || cp(1) > pos(1)+pos(3) || cp(2) < pos(2) || cp(2) > pos(2)+pos(4)
                    continue;
                end
                hoveredIdx = i;
                xl = xlim(obj.ax(i));
                rawT = xl(1) + (cp(1)-pos(1)) / pos(3) * diff(xl);
                xs = obj.axSnapX{i};
                if isempty(xs)
                    snappedT = rawT;
                else
                    [dmin, k] = min(abs(xs - rawT));
                    snappedT = xs(k);
                    targetLine = obj.axSnapLines{i}(obj.axSnapLineOfVertex{i}(k));
                    localIdx = obj.axSnapLocalIdx{i}(k);
                    distPix = dmin / diff(xl) * pos(3);
                end
                return;
            end
        end

        function hideDataTip(obj)
            % hideDataTip()
            %   Hides the floating hover data-tip popup (no-op if it was
            %   never created, e.g. on Octave). Called when a pan/zoom
            %   interaction starts, since the tip is not updated during
            %   those and would otherwise sit frozen on screen.

            if ~isempty(obj.hDataTipBox) && isvalid(obj.hDataTipBox)
                set(obj.hDataTipBox, 'Visible', 'off');
            end
        end

        function updateDataTipFromCursor(obj, hoveredIdx, targetLine, localIdx, distPix)
            % updateDataTipFromCursor(hoveredIdx, targetLine, localIdx, distPix)
            %   Shows/updates the floating hover data-tip popup
            %   (obj.hDataTipBox) near the cursor when it sits within
            %   dataTipPixelThresh pixels of the waveform vertex found by
            %   findHoverPoint, using buildTipLines for the popup content
            %   (the same content DataTipHandler used to build for
            %   MATLAB's built-in hover data tip). Hides the popup
            %   otherwise. Called from onMmbDrag on every mouse move.

            if isempty(obj.hDataTipBox) || ~isvalid(obj.hDataTipBox)
                return;
            end
            if isempty(hoveredIdx) || isempty(targetLine) || distPix > obj.dataTipPixelThresh
                obj.hideDataTip();
                return;
            end
            xd = get(targetLine, 'XData');
            yd = get(targetLine, 'YData');
            tVal = xd(localIdx);
            yVal = yd(localIdx);
            out = obj.buildTipLines(obj.ax(hoveredIdx), targetLine, tVal, yVal);
            cp = obj.f.CurrentPoint;
            set(obj.hDataTipBox, 'String', out, 'Position', [cp(1)+12, cp(2)+12, 1, 1], 'Visible', 'on');
        end
    end
end

