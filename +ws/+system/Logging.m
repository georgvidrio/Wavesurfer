classdef Logging < ws.system.Subsystem
    % Logging  Subsystem that logs data to disk.
    
    properties (Dependent=true)
        FileLocation  % absolute path of data file directory
        FileBaseName  % prefix for data file name to which trial index will be appended
        IsOKToOverwrite  % logical, whether it's OK to overwrite data files without warning
        NextTrialIndex  % the index of the next trial (one-based).  (This gets reset if you change the FileBaseName.)
    end
    
    properties (Dependent=true, SetAccess=immutable)
        NextTrialSetAbsoluteFileName
    end
    
    properties (Access = protected)
        FileLocation_
        FileBaseName_
        IsOKToOverwrite_
        NextTrialIndex_
    end
    
    % These are all properties that are only used when acquisition is
    % ongoing.  They are set in willPerformExperiment(), and are nulled in
    % didPerformExperiment() and didAbortExperiment()
    properties (Access = protected, Transient=true)
        LogFileNameAbsolute_
        CurrentDatasetOffset_
            % during acquisition, the index of the next "scan" to be written (one-based)
            % "scan" is an NI-ism meaning all the samples acquired for a
            % single time stamp
        ExpectedTrialSize_  
            % if all the acquired data for one trial were put into an array, this
            % would be the size of that array.  
            % I.e. [nScans nActiveChannels]        
        WriteToTrialId_  % During the acquisition of a trial set, the current trial index being written to
        ChunkSize_
        FirstTrialIndex_  % index of the first trial in the ongoing trial set
        DidCreateCurrentDataFile_  % whether the data file for the current trial set has been created
        LastTrialIndexForWhichDatasetCreated_  
          % For the current file/trialset, the trial index of the most-recently dataset in the data file.
          % Empty if the no dataset has yet been created for the current file.
        DidWriteSomeDataForThisTrial_
    end

    events
        DidSetFileLocation
        DidSetFileBaseName
        DidSetIsOKToOverwrite
        DidSetNextTrialIndex
    end
    
    methods
        function self = Logging(parent)
            self.CanEnable=true;            
            self.Parent=parent;
            self.FileLocation_ = 'C:\Data';
            self.FileBaseName_ = 'untitled';
            self.IsOKToOverwrite = false;
            self.NextTrialIndex_ = 1; % Number of trials acquired since value was reset + 1 (reset occurs automatically on FileBaseName change).
        end
        
        function delete(self)
            self.Parent=[];
        end
        
        function set.FileLocation(self, newValue)
            if isa(newValue,'ws.most.util.Nonvalue'), return, end            
            self.validatePropArg('FileLocation', newValue);
            if ~exist(newValue,'dir') ,
                return
            end
            originalValue=self.FileLocation_;
            self.FileLocation_ = newValue;
            % If file name has changed, reset the trial index
            originalFullName=fullfile(originalValue,self.FileBaseName);
            newFullName=fullfile(newValue,self.FileBaseName);
            if ~isequal(originalFullName,newFullName) ,
                self.NextTrialIndex = 1;
            end
            self.broadcast('DidSetFileLocation');
        end
        
        function result=get.FileLocation(self)
            result=self.FileLocation_;
        end
        
        function set.FileBaseName(self, newValue)
            %fprintf('Entered set.FileBaseName()\n');            
            if isa(newValue,'ws.most.util.Nonvalue'), return, end            
            self.validatePropArg('FileBaseName', newValue);
            originalValue=self.FileBaseName_;
            self.FileBaseName_ = newValue;
            % If file name has changed, reset the trial index
            originalFullName=fullfile(self.FileLocation,originalValue);
            newFullName=fullfile(self.FileLocation,newValue);
            if ~isequal(originalFullName,newFullName) ,
                %fprintf('About to reset NextTrialIndex...\n');
                self.NextTrialIndex = 1;
            end
            self.broadcast('DidSetFileBaseName');            
        end
        
        function result=get.FileBaseName(self)
            result=self.FileBaseName_;
        end
            
        function set.IsOKToOverwrite(self, newValue)
            if isnan(newValue), return, end            
            self.validatePropArg('IsOKToOverwrite', newValue);
            self.IsOKToOverwrite_ = newValue;
            self.broadcast('DidSetIsOKToOverwrite');            
        end
        
        function result=get.IsOKToOverwrite(self)
            result=self.IsOKToOverwrite_;
        end
        function set.NextTrialIndex(self, newValue)
            if isa(newValue,'ws.most.util.Nonvalue'), return, end            
            self.validatePropArg('NextTrialIndex', newValue);
            self.NextTrialIndex_ = newValue;
            self.broadcast('DidSetNextTrialIndex');            
        end
        
        function result=get.NextTrialIndex(self)
            result=self.NextTrialIndex_;
        end           

        function value=get.NextTrialSetAbsoluteFileName(self)
            wavesurferModel=self.Parent;
            %if wavesurferModel.IsTrialBased ,
            firstTrialIndex = self.NextTrialIndex ;
            numberOfTrials = wavesurferModel.ExperimentTrialCount ;
            fileName = self.trialSetFileNameFromNumbers_(firstTrialIndex,numberOfTrials);
%             elseif wavesurferModel.IsContinuous ,
%                 dateAndTimeAffix = strrep(strrep(datestr(now()), ' ', '_'), ':', '-') ;
%                 fileName = sprintf('%s-continuous_%s', self.FileBaseName, dateAndTimeAffix);                
%             else
%                 error('wavesurfer:internalError' , ...
%                       'Unable to determine trial set file name');
%             end
            value = fullfile(self.FileLocation, fileName);
        end  % function
        
        function willPerformExperiment(self, wavesurferModel, desiredApplicationState)
            if isempty(self.FileBaseName) ,
                error('wavesurfer:saveddatasystem:emptyfilename', 'Data logging can not be enabled with an empty filename.');
            end
            
            % Note that we have not yet created the current data file
            self.DidCreateCurrentDataFile_ = false ;
            
            % Set the chunk size for writing data to disk
            active = sum(wavesurferModel.Acquisition.IsChannelActive & wavesurferModel.Acquisition.IsChannelAnalog);
            switch desiredApplicationState ,
                case ws.ApplicationState.AcquiringTrialBased ,
                    self.ExpectedTrialSize_ = [wavesurferModel.Acquisition.ExpectedScanCount active];
                    if any(isinf(self.ExpectedTrialSize_))
                        self.ChunkSize_ = [wavesurferModel.Acquisition.SampleRate active];
                    else
                        self.ChunkSize_ = self.ExpectedTrialSize_;
                    end
%                     if wavesurferModel.ExperimentTrialCount == 1 ,
%                         trueLogFileName = sprintf('%s_%04d', self.FileBaseName, self.NextTrialIndex);
%                     else
%                         trueLogFileName = sprintf('%s_%04d-%04d', ...
%                                                   self.FileBaseName, ...
%                                                   self.NextTrialIndex, ...
%                                                   self.NextTrialIndex + wavesurferModel.ExperimentTrialCount - 1);
%                     end
                case ws.ApplicationState.AcquiringContinuously ,
                    self.ExpectedTrialSize_ = [Inf active];
                    self.ChunkSize_ = [wavesurferModel.Acquisition.SampleRate active];
%                     trueLogFileName = sprintf('%s-continuous_%s', self.FileBaseName, strrep(strrep(datestr(now), ' ', '_'), ':', '-'));
                otherwise
                    error('wavesurfer:saveddatasystem:invalidmode', ...
                          sprintf('%s is not a supported mode for data logging.', char(desiredApplicationState))); %#ok<SPERR>
            end
            
            % Determine the absolute file names
            %self.LogFileNameAbsolute_ = fullfile(self.FileLocation, [trueLogFileName '.h5']);
            self.LogFileNameAbsolute_ = self.NextTrialSetAbsoluteFileName ;
            
            % Store the first trial index for the trial set 
            self.FirstTrialIndex_ = self.NextTrialIndex ;
            
            % If the target dir doesn't exist, create it
            if ~exist(self.FileLocation, 'dir')
                mkdir(self.FileLocation);
            end
            
            % Check for filename collisions, if that's what user wants
            if self.IsOKToOverwrite ,
                % don't need to check anything
                % But need to delete pre-existing files, otherwise h5create
                % will just add datasets to a pre-existing file.
                if exist(self.LogFileNameAbsolute_, 'file') == 2 ,
                    ws.utility.deleteFileWithoutWarning(self.LogFileNameAbsolute_);
                end
%                 if exist(sidecarFileNameAbsolute, 'file') == 2 ,
%                     ws.utility.deleteFileWithoutWarning(sidecarFileNameAbsolute);
%                 end
            else
                % Check if the log file already exists, and error if so
                if exist(self.LogFileNameAbsolute_, 'file') == 2 ,
                    error('wavesurfer:logFileAlreadyExists', ...
                          'The data file %s already exists', self.LogFileNameAbsolute_);
                end
%                 if exist(sidecarFileNameAbsolute, 'file') == 2 ,
%                     error('wavesurfer:sidecarFileAlreadyExists', ...
%                           'The sidecar file %s already exists', self.LogFileNameAbsolute_);
%                 end
            end

            % Extract all the "headerable" info in the WS model into a
            % structure
            headerStruct = wavesurferModel.encodeForFileType('header');
            
            % Put the header into into the log file header
            %numericPrecision=4;
            %stringOfAssignmentStatements= ws.most.util.structOrObj2Assignments(headerStruct, 'header', [], numericPrecision);
            doCreateFile=true;
            %ws.most.fileutil.h5savestr(self.LogFileNameAbsolute_, '/headerstr', stringOfAssignmentStatements, doCreateFile);
            ws.most.fileutil.h5save(self.LogFileNameAbsolute_, '/header', headerStruct, doCreateFile);
            self.DidCreateCurrentDataFile_ = true ;
            
%             % Save the "header" information to a sidecar file instead.
%             % This should be more flexible that embedding the "header" data
%             % in with the data sensu strictu.
%             save('-mat',sidecarFileNameAbsolute,'-struct','headerStruct');
            
            % Set the write-to trial ID so it's correct when data needs to
            % be written
            self.WriteToTrialId_ = self.NextTrialIndex;
            
            % Add an HDF "dataset" for each active AI channel, for each
            % trial.
            % TODO: Try moving the dataset creation for each trial to
            % willPerformTrial() --- This is the cause of slowness at trial
            % set start for Justin Little, possibly others.
%             if ~isempty(wavesurferModel.Acquisition) ,
%                 for indexOfTrialWithinSet = 1:wavesurferModel.ExperimentTrialCount ,
%                     h5create(self.LogFileNameAbsolute_, ...
%                              sprintf('/trial_%04d', ...
%                                      self.WriteToTrialId_ + (indexOfTrialWithinSet-1)), ...
%                              self.ExpectedTrialSize_, ...
%                              'ChunkSize', chunkSize, ...
%                              'DataType','int16');
%                 end
%             end
            
            % The next incoming scan will be written to this (one-based)
            % index in the dataset
            self.CurrentDatasetOffset_ = 1;
            
            % This should be empty until we create a dataset for a trial
            self.LastTrialIndexForWhichDatasetCreated_ = [] ;
            
            % For tidyness
            self.DidWriteSomeDataForThisTrial_ = [] ;
        end
        
        function willPerformTrial(self, wavesurferModel) %#ok<INUSD>
            %profile resume
            thisTrialIndex = self.NextTrialIndex ;
            timestampDatasetName = sprintf('/trial_%04d/timestamp',thisTrialIndex) ;
            h5create(self.LogFileNameAbsolute_, timestampDatasetName, [1 1]);  % will consist of one double
            scansDatasetName = sprintf('/trial_%04d/analogScans',thisTrialIndex) ;
            h5create(self.LogFileNameAbsolute_, ...
                     scansDatasetName, ...
                     self.ExpectedTrialSize_, ...
                     'ChunkSize', self.ChunkSize_, ...
                     'DataType','int16');
            scansDatasetName = sprintf('/trial_%04d/digitalScans',thisTrialIndex) ;
            % TODO: Probably need to change to number of active digital channels
            % below
            if self.Parent.Acquisition.NDigitalChannels<=8
                dataType = 'uint8';
            elseif self.Parent.Acquisition.NDigitalChannels<=16
                dataType = 'uint16';
            else %self.Parent.Acquisition.NDigitalChannels<=32
                dataType = 'uint32';
            end
            if self.Parent.Acquisition.NDigitalChannels>0 ,
                h5create(self.LogFileNameAbsolute_, ...
                         scansDatasetName, ...
                         [self.ExpectedTrialSize_(1) 1], ...
                         'ChunkSize', [self.ChunkSize_(1) 1], ...
                         'DataType',dataType);
            end
            self.LastTrialIndexForWhichDatasetCreated_ =  thisTrialIndex;                     
            self.DidWriteSomeDataForThisTrial_ = false ;
            %profile off
        end
        
        function didPerformTrial(self, wavesurferModel) %#ok<INUSD>
            %if wavesurferModel.State == ws.ApplicationState.AcquiringTrialBased ,
                self.NextTrialIndex = self.NextTrialIndex + 1;
            %end
        end
        
        function didAbortTrial(self, wavesurferModel) %#ok<INUSD>
            %if wavesurferModel.State == ws.ApplicationState.AcquiringTrialBased ,
                if isempty(self.LastTrialIndexForWhichDatasetCreated_) ,
                    if isempty(self.FirstTrialIndex_) ,
                        % This probably means there was some sort of error
                        % before the trial even started.  So just leave
                        % NextTrialIndex alone.
                    else
                        % In this case, no datasets were created, so put the
                        % trial index to the FirstTrialIndex for the set
                        self.NextTrialIndex = self.FirstTrialIndex_ ;
                    end
                else
                    self.NextTrialIndex = self.LastTrialIndexForWhichDatasetCreated_ + 1;
                end
            %end
        end
        
        function didPerformExperiment(self, ~)
            self.didPerformOrAbortExperiment_();
        end
        
        function didAbortExperiment(self, wavesurferModel) %#ok<INUSD>
            %fprintf('Logging::didAbortExperiment()\n');
        
            %dbstop if caught
            %
            % Want to rename the data file to reflect the actual number of trials acquired
            %
            exception = [] ;
            if self.DidCreateCurrentDataFile_ ,
                % A data file was created.  Might need to rename it, or delete it.
                originalAbsoluteLogFileName = self.LogFileNameAbsolute_ ;
                firstTrialIndex = self.FirstTrialIndex_ ;
                if isempty(self.LastTrialIndexForWhichDatasetCreated_) ,
                    % This means no trials were actually added to the log file.
                    numberOfPartialTrialsLogged = 0 ;
                else                    
                    numberOfPartialTrialsLogged = self.LastTrialIndexForWhichDatasetCreated_ - firstTrialIndex + 1 ;  % includes complete and partial trials
                end
                if numberOfPartialTrialsLogged == 0 ,
                    % If no trials logged, and we actually created the data file for the current trial set, delete the file
                    if self.DidCreateCurrentDataFile_ ,
                        ws.utility.deleteFileWithoutWarning(originalAbsoluteLogFileName);
                    else
                        % nothing to do
                    end
                else    
                    % We logged some trials, but maybe not the number number requested.  Check for this, renaming the
                    % data file if needed.
                    newLogFileName = self.trialSetFileNameFromNumbers_(firstTrialIndex,numberOfPartialTrialsLogged) ;
                    newAbsoluteLogFileName = fullfile(self.FileLocation, newLogFileName);
                    if isequal(originalAbsoluteLogFileName,newAbsoluteLogFileName) ,
                        % This might happen, e.g. if the number of trials is inf
                        % do nothing.
                    else
                        % Check for filename collisions, if that's what user wants
                        if exist(newAbsoluteLogFileName, 'file') == 2 ,
                            if self.IsOKToOverwrite ,
                                % don't need to check anything
                                % But need to delete pre-existing files, otherwise h5create
                                % will just add datasets to a pre-existing file.
                                ws.utility.deleteFileWithoutWarning(newAbsoluteLogFileName);
                            else
                                exception = MException('wavesurfer:unableToRenameLogFile', ...
                                                       'Unable to rename data file after abort, because file %s already exists', newLogFileName);
                            end
                        end
                        % If all is well here, rename the file
                        if isempty(exception) ,
                            movefile(originalAbsoluteLogFileName,newAbsoluteLogFileName);
                        end                
                    end
                end
            else
                % No data file was created, so nothing to do.
            end

            % Now do things common to performance and abortion
            self.didPerformOrAbortExperiment_();

            % Now throw that exception, if there was one
            %dbclear all
            if isempty(exception) ,                
                % do nothing
            else
                throw(exception);
            end            
         end  % function
            
    end
    
    methods (Access=protected)
%         function didPerformOrAbortTrial_(self, wavesurferModel)
%             if wavesurferModel.State == ws.ApplicationState.AcquiringTrialBased ,
%                 self.NextTrialIndex = self.NextTrialIndex + 1;
%             end
%         end
        
        function didPerformOrAbortExperiment_(self)
            % null-out all the transient things that are only used during
            % the trial set
            self.LogFileNameAbsolute_ = [];
            self.FirstTrialIndex_ = [] ;
            self.CurrentDatasetOffset_ = [];
            self.ExpectedTrialSize_ = [];
            self.WriteToTrialId_ = [];
            self.ChunkSize_ = [];
            self.DidCreateCurrentDataFile_ = [] ;
            self.LastTrialIndexForWhichDatasetCreated_ = [] ;
            self.DidWriteSomeDataForThisTrial_ = [] ;
        end
    end

    methods
        function dataAvailable(self, state, t, scaledAnalogData, rawAnalogData, rawDigitalData, timeSinceExperimentStartAtStartOfData) %#ok<INUSL>
            %ticId=tic();
            
%             if self.Parent.State == ws.ApplicationState.TestPulsing || self.CurrentDatasetOffset_ < 1
%                 return
%             end
            
            %dataSingle=single(scaledData);
            %inputChannelNames=self.Parent.Acquisition.ActiveChannelNames;
            %nActiveChannels=self.Parent.Acquisition.NActiveChannels;
            if ~self.DidWriteSomeDataForThisTrial_ ,
                timestampDatasetName = sprintf('/trial_%04d/timestamp',self.WriteToTrialId_) ;
                h5write(self.LogFileNameAbsolute_, timestampDatasetName, timeSinceExperimentStartAtStartOfData);
                self.DidWriteSomeDataForThisTrial_ = true ;  % will be true momentarily...
            end
            
            if ~isempty(self.FileBaseName) ,
                h5write(self.LogFileNameAbsolute_, ...
                        sprintf('/trial_%04d/analogScans', ...
                                self.WriteToTrialId_), ...
                        rawAnalogData, ...
                        [self.CurrentDatasetOffset_ 1], ...
                        size(rawAnalogData));
                if ~isempty(rawDigitalData) ,
                    h5write(self.LogFileNameAbsolute_, ...
                            sprintf('/trial_%04d/digitalScans', ...
                                    self.WriteToTrialId_), ...
                            rawDigitalData, ...
                            [self.CurrentDatasetOffset_ 1], ...
                            size(rawDigitalData));
                end
            end
            
            self.CurrentDatasetOffset_ = self.CurrentDatasetOffset_ + size(scaledAnalogData, 1);
            
            if self.CurrentDatasetOffset_ > self.ExpectedTrialSize_(1) ,
                self.CurrentDatasetOffset_ = 1;
                self.WriteToTrialId_ = self.WriteToTrialId_ + 1;
            end
            %T=toc(ticId);
            %fprintf('Time in Logging.dataAvailable(): %0.3f s\n',T);
        end
    end
    
    methods (Access = protected)
        function fileName = trialSetFileNameFromNumbers_(self,firstTrialIndex,numberOfTrials)
            % This is a "leaf" file name, not an absolute one
            if numberOfTrials == 1 ,
                fileName = sprintf('%s_%04d.h5', self.FileBaseName, firstTrialIndex);
            else
                if isfinite(numberOfTrials) ,
                    lastTrialIndex = firstTrialIndex + numberOfTrials - 1 ;
                    fileName = sprintf('%s_%04d-%04d.h5', ...
                                       self.FileBaseName, ...
                                       firstTrialIndex, ...
                                       lastTrialIndex);
                else
                    fileName = sprintf('%s_%04d-.h5', ...
                                       self.FileBaseName, ...
                                       firstTrialIndex);
                end
            end            
        end  % function        
    end  % static methods block
    
    methods (Access = protected)
        function defineDefaultPropertyAttributes(self)
            defineDefaultPropertyAttributes@ws.system.Subsystem(self);
            self.setPropertyAttributeFeatures('FileLocation', 'Classes', 'char', 'Attributes', {'vector'});
            self.setPropertyAttributeFeatures('FileBaseName', 'Classes', 'char', 'Attributes', {'vector'});
            self.setPropertyAttributeFeatures('NextTrialIndex', 'Attributes', {'scalar', 'finite', 'integer', '>=', 1});
        end
        
%         function defineDefaultPropertyTags(self)
%             defineDefaultPropertyTags@ws.system.Subsystem(self);            
%             % self.setPropertyTags('Enabled', 'ExcludeFromFileTypes', {'*'});  
%             %self.setPropertyTags('Enabled', 'IncludeInFileTypes', {'cfg'});
%             %self.setPropertyTags('Enabled', 'ExcludeFromFileTypes', {'usr'});            
%             self.setPropertyTags('FileLocation', 'IncludeInFileTypes', {'cfg'});
%             self.setPropertyTags('FileBaseName', 'IncludeInFileTypes', {'cfg'});
%             self.setPropertyTags('NextTrialIndex', 'IncludeInFileTypes', {'cfg'});
%         end
        
%         function zprvFileLocationWillChange(self, ~, ~)
%             self.CachedLoggingFileNameInfo_{1} = self.FileLocation;
%         end
%         
%         function zprvFileBaseNameWillChange(self, ~, ~)
%             self.CachedLoggingFileNameInfo_{2} = self.FileBaseName;
%         end
%         
%         function zprvFileLocationOrBaseNameDidChange(self, ~, ~)
%             % MATLAB loves to fire set events when the value does not actually change.
%             if ~strcmp(fullfile(self.CachedLoggingFileNameInfo_{1}, self.CachedLoggingFileNameInfo_{2}), fullfile(self.FileLocation, self.FileBaseName))
%                 self.NextTrialIndex = 1;
%             end
%         end
    end
    
%     methods (Access=public)
%         function resetProtocol(self)  % has to be public so WavesurferModel can call it
%             % Clears all aspects of the current protocol (i.e. the stuff
%             % that gets saved/loaded to/from the config file.  Idea here is
%             % to return the protocol properties stored in the model to a
%             % blank slate, so that we're sure no aspects of the old
%             % protocol get carried over when loading a new .cfg file.
%             
%             self.Enabled=true;
%             self.FileBaseName='untitled';
%             self.FileLocation='C:\Data';
%             self.NextTrialIndex=1;
%         end  % function
%     end % methods

    methods (Access=protected)        
        function out = getPropertyValue(self, name)
            out = self.(name);
        end  % function
        
        % Allows access to protected and protected variables from ws.mixin.Coding.
        function setPropertyValue(self, name, value)
            self.(name) = value;
        end  % function
    end
    
    properties (Hidden, SetAccess=protected)
        mdlPropAttributes = ws.system.Logging.propertyAttributes();
        
        mdlHeaderExcludeProps = {};
    end
    
    methods (Static)
        function s = propertyAttributes()
            s = ws.system.Subsystem.propertyAttributes();

            s.FileLocation = struct('Classes', 'string');
            s.FileBaseName = struct('Classes', 'string');
            s.NextTrialIndex = struct('Attributes', {{'scalar', 'finite', 'integer', '>=', 1}});
            s.IsOKToOverwrite = struct('Classes','binarylogical', 'Attributes', {{'scalar'}} );            
        end  % function
    end  % class methods block
    
    
end
