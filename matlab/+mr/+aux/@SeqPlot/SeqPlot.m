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
            end
            parse(parser,varargin{:});
            opt = parser.Results;

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

            if ~mr.aux.isOctave()
              obj.ax = gobjects(1,6);
            end
            for i=1:6
                obj.ax(i)=subplot(3,2,i);
            end
            obj.ax=obj.ax([1 3 5 2 4 6]);   % Re-order axes
            arrayfun(@(x)hold(x,'on'),obj.ax);
            arrayfun(@(x)grid(x,'on'),obj.ax);
            obj.labels={'ADC/lbl/trig','RF mag (Hz)','RF/ADC ph (rad)','Gx (kHz/m)','Gy (kHz/m)','Gz (kHz/m)'};
            arrayfun(@(x)ylabel(obj.ax(x),obj.labels{x}),1:6);
            if ~mr.aux.isOctave()
                % hide the per-axes interactive toolbar; the custom
                % control panel provides zoom/pan/show-hide instead
                arrayfun(@(x)set(x.Toolbar,'Visible','off'),obj.ax);
            end

            tFactorList = [1 1e3 1e6];
            tFactor = tFactorList(strcmp(opt.timeDisp,validTimeUnits));
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
              hDCM.UpdateFcn = @(src, event)DataTipHandler(obj,tFactor,[timeFormat ' ' opt.timeDisp],src,event);
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
                for i=1:6
                    xax=get(obj.ax(i),'XAxis');
                    xax.ExponentMode='manual';
                    xax.Exponent=0;
                end
            end
            if opt.showBlocks
                % show block edges in plots
                for i=1:6
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

            % loop through blocks
            for iB=1:length(seq.blockEvents)
                block = seq.getBlock(iB);
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
                if t0<=timeRange(2)
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
                isValid = t0+seq.blockDurations(iB)>timeRange(1) && t0<=timeRange(2);
                if isValid
                    if isfield(block,'trig') && ~isempty(block.trig)
                        switch(block.trig.type)
                            case 'output'
                                % plot digital output triggers in the RF-TX pane
                                p2x=plot(tFactor*(t0+block.trig.delay),0,'diamond','Color',[0 0.5 0],'Parent',obj.ax(1));
                                p2x=plot(tFactor*(t0+block.trig.delay +[0 block.trig.duration]),[0 0],'-','Marker','.','Color',[0 0.5 0],'Parent',obj.ax(1));
                            case 'trigger'
                                p1x=plot(tFactor*(t0+block.trig.delay),0,'>b','Parent',obj.ax(1));
                                p1x=plot(tFactor*(t0+block.trig.delay),0,'.b','Parent',obj.ax(1));
                            %otherwise
                        end
                    end
                    if ~isempty(block.adc)
                        adc=block.adc;
                        t=adc.delay + ((0:adc.numSamples-1)'+0.5)*adc.dwell; % according to the information from Klaus Scheffler and indirectly from Siemens this is the present convention (the samples are shifted by 0.5 dwell)
                        p1=plot(tFactor*(t0+t),zeros(size(t)),'rx','Parent',obj.ax(1));
                        if isempty(adc.phaseModulation)
                            adc.phaseModulation=0;
                        end
                        full_freqOffset=adc.freqOffset+adc.freqPPM*1e-6*seq.sys.gamma*seq.sys.B0;
                        full_phaseOffset=adc.phaseOffset+adc.phasePPM*1e-6*seq.sys.gamma*seq.sys.B0;
                        p2=plot(tFactor*(t0+t), angle(exp(1i*(full_phaseOffset+adc.phaseModulation)).*exp(1i*2*pi*t*full_freqOffset)),'b.','MarkerSize',1,'Parent',obj.ax(3)); % plot ADC phase
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
                            p1=plot(tFactor*(t0+t+rf.delay),  real(s),'Parent',obj.ax(2));
                            p2=plot(tFactor*(t0+t+rf.delay),  angle(s.*sign(real(s))*exp(1i*full_phaseOffset).*exp(1i*2*pi*t    *full_freqOffset)), tFactor*(t0+tc+rf.delay), angle(sc*exp(1i*full_phaseOffset).*exp(1i*2*pi*tc*full_freqOffset)),'xb', 'Parent',obj.ax(3));
                        else
                            p1=plot(tFactor*(t0+t+rf.delay),  abs(s),'Parent',obj.ax(2));
                            p2=plot(tFactor*(t0+t+rf.delay),  angle(s*exp(1i*full_phaseOffset).*exp(1i*2*pi*t    *full_freqOffset)), tFactor*(t0+tc+rf.delay), angle(sc*exp(1i*full_phaseOffset).*exp(1i*2*pi*tc*full_freqOffset)),'xb', 'Parent',obj.ax(3));
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
                            p=plot(tFactor*(t0+t),waveform,'Parent',obj.ax(3+j));
                        end
                    end
                end
                t0=t0+seq.blockDurations(iB);%mr.calcDuration(block);
            end

            % Set axis limits and zoom properties
            dispRange = tFactor*[timeRange(1) min(timeRange(2),t0)];
            obj.initialXLim = dispRange;
            arrayfun(@(x)xlim(x,dispRange),obj.ax);
            linkaxes(obj.ax(:),'x')
            if ~mr.aux.isOctave()
              h = zoom(obj.f);
              setAxesZoomMotion(h,obj.ax(1),'horizontal');
              p = pan(obj.f);
              p.Motion = 'horizontal';
            end
            % manually fix the phase vertical scale to +- pi
            ylim(obj.ax(3),[-pi pi]);
            % make Y-axes little bit less tight
            arrayfun(@(x) ylim(x, ylim(x) + 0.03*[-1 1]*sum(ylim(x).*[-1 1])), obj.ax(2:end));

            obj.initialYLim = zeros(numel(obj.ax), 2);
            for ii = 1:numel(obj.ax)
                obj.initialYLim(ii,:) = ylim(obj.ax(ii));
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
            %   share one column (in their original top-to-bottom order);
            %   otherwise they are arranged in the original two columns
            %   (ADC/lbl/trig, RF mag, RF/ADC ph | Gx, Gy, Gz).

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
                columns = {1:numel(obj.ax)};
            else
                columns = {[1 2 3], [4 5 6]};
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
            else
                pan(obj.f, 'off');
            end
            obj.removeFocus(src);
        end

        function out=DataTipHandler(obj, tfactor, timeFormat, src, event)
            if ~isa(event,'matlab.graphics.internal.DataTipEvent') || ...
               ~isprop(event, 'Position') || length(event.Position)<2 || ...
               ~isprop(event, 'Target')
                out=[];
                return;
            end
            ax=src.Host.Parent;
            % get the relevant target from the y-axes title
            at=lower(ax.YLabel.String);
            if strcmp(at(1:3),'adc') || ...
               (strcmp(at(1:6),'rf/adc') && strcmp(event.Target.LineStyle,'none') && strcmp(event.Target.Marker,'.')) % we need to check whether we are dealing with the ADC phase, which is also shown in the same panel as the RF
                field='adc';
            else
                field=at(1:2);
            end
            % create the custom data tip as tex-formatted cell array of lines
            t=event.Position(1);
            t0=t;
            if isa(event.Target,'matlab.graphics.chart.primitive.Line')
                % for trapezoid gradients the last point may belong to the next block
                t0=event.Target.XData(1);
            end
            iB=obj.hSeq.findBlockByTime(t0/tfactor);
            rb=obj.hSeq.getRawBlockContentIDs(iB);
            out={['\bf\color{blue}t:\rm\color{black}' sprintf(timeFormat,t)],...
                 ['\bf\color{blue}Y:\rm\color{black}' num2str(event.Position(2))],...
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

            % we need to delay the call of the update, otherwise the plot
            % object generates an exception
            t=timer('StartDelay',0e-3,'Period',1e-3,'TimerFcn',@(~,~)updateGuides(obj,t));
            t.start();
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
    end
end

