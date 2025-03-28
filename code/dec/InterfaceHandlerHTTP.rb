#!/usr/bin/env ruby

### https://www.w3.org/Protocols/rfc2616/rfc2616-sec9.html

### HTTP verbs used:
### > HEAD: same as GET but does not return the message body (to list files prior pull operations)

require 'ctc/WrapperCURL'
require 'dec/ReadInterfaceConfig'
require 'dec/ReadConfigOutgoing'
require 'dec/ReadConfigIncoming'
require 'dec/InterfaceHandlerAbstract'

require 'uri'
require 'net/http'
require 'curb'
require 'open-uri'
require 'nokogiri'
require 'fileutils'

module DEC


class InterfaceHandlerHTTP < InterfaceHandlerAbstract

   include CTC::WrapperCURL

   ## -----------------------------------------------------------
   ##
   ## Class constructor.
   ## * entity (IN):  Entity textual name (i.e. FOS)
   def initialize(entity, log, pull=true, push=true, manageDirs=false, isDebug=false)
      @entity     =  entity
      @logger     =  log
      @manageDirs =  manageDirs
      
      if isDebug == true then
         self.setDebugMode
      else
         @isDebugMode = false
      end

      @entityConfig     = ReadInterfaceConfig.instance
      @outConfig        = ReadConfigOutgoing.instance
      @inConfig         = ReadConfigIncoming.instance
      @isSecure         = @entityConfig.isSecure?(@entity)
      @server           = @entityConfig.getServer(@entity)
      @verifyPeerSSL    = @entityConfig.isVerifyPeerSSL?(@entity)
      @uploadDir        = @outConfig.getUploadDir(@entity)
      @arrPullDirs      = @inConfig.getDownloadDirs(@entity)    
      @http             = nil
      @url              = nil   
   end   
   ## -----------------------------------------------------------
   ##
   ## Set the flag for debugging on
   def setDebugMode
      @isDebugMode = true
      @logger.debug("InterfaceHandlerHTTP debug mode is on") 
   end
   ## -----------------------------------------------------------

   def pushFile(file)
      url = ""
      
      if @uploadDir[0,1] == '/' then
         url = "#{@server[:hostname]}:#{@server[:port]}#{@uploadDir}"
      else
         url = "#{@server[:hostname]}:#{@server[:port]}/#{@uploadDir}"
      end
      
      if @server[:isSecure] == false then
         url = "http://#{url}"
      else
         url = "https://#{url}/"
      end
      
      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::pushFile => #{file} / #{@url} by @server[:user]")
      end
      return putFile(url, @verifyPeerSSL, @server[:user], @server[:password], file, @isDebugMode, @logger)
   end
   ## -----------------------------------------------------------

   ## -----------------------------------------------------------

   def checkConfig(entity, pull, push)
      checker     = CheckerInterfaceConfig.new(entity, pull, push, @logger, @isDebugMode)
      
      if @isDebugMode == true then
         checker.setDebugMode
      end
      
      retVal      = checker.check
 
      if retVal == true then
         if @isDebugMode == true then
            @logger.debug("#{entity} I/F is configured correctly")
 	      end
      else
         raise "[DEC_000] I/F #{entity}: init / configuration problem"
      end
   end

   ## -----------------------------------------------------------

  
   ## -----------------------------------------------------------

   def getUploadDirList(bTemp = false)
      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::getUploadDirList tmp => #{bTemp}")
      end
      
      dir      = nil
      
      if bTemp == false then
         dir = @outConfig.getUploadDir(@entity)
      else
         dir = @outConfig.getUploadTemp(@entity)
      end
      
      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::getUploadDirList tmp => #{bTemp} / #{dir}")
      end
   
      return self.getDirList(dir)
   
   end
   ## -----------------------------------------------------------
   
   def getPullList(bShortCircuit = false)
      newArrFile = Array.new      
      @arrPullDirs.each{|element|
         dir         = element[:directory]
         @maxDepth   = element[:depthSearch]
         # ---------------------------------------
         # URL ends with "/" treat it as a directory         
         if dir[-1, 1] == "/" then
            newArrFile << getDirList(dir, bShortCircuit)
            next
         else
            newArrFile << getListFile(dir, bShortCircuit)
            next         
         end 
         # ---------------------------------------
      }
      return newArrFile.flatten
   end
   ## -----------------------------------------------------------
   
   ## Need to make it pure HTTP
   
   def getDirList(remotePath, shortCircuit = false)
      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::getDirList => #{remotePath} url treated as a directory / DepthSearch = #{@maxDepth}")
      end

      host        = ""
      url         = ""
      uri         = nil
      port        = @server[:port].to_i
      user        = @server[:user]
      pass        = @server[:password]
   
      if @isSecure == false then
         host        = "http://#{@server[:hostname]}:#{@server[:port]}/"
      else
         host        = "https://#{@server[:hostname]}/"
      end

      # This is if getDirList is invoked with a full link / depthsearch > 0
      if remotePath.include?("://") == false then
         url = "#{host}#{remotePath}"
         uri = URI.parse(url)
      else
         url = remotePath
         uri = URI.parse(url)
      end
      
      ## ------------------
      ## Request headers
      response = nil
      response = Net::HTTP.get_response(uri)
      
      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::getDirList => HTTP HEAD #{url} => #{response.code}")
      end

=begin         
         <div class="archiveItem">
         <div class="archiveItemImgContainer">
         <img src="/css/images/txtFile_18x25.png" alt="[file]"></div><!-- end imgContainer-->
         <div class="archiveItemTextContainer"><a class="archiveItemText" id="c1pg0480.25i.Z" title="DataFile" href="c1pg0480.25i.Z ">c1pg0480.25i.Z</a> <span class="fileInfo">2025:02:17 06:51:24    216.4veItem-->
         </div><!-- end item-->
=end
      if response.code.to_i == 302 then
         if @isDebugMode == true
            @logger.debug("InterfaceHandlerHTTP::getDirList => REDIRECTION - 302 for #{uri}")
            @logger.debug("InterfaceHandlerHTTP::getDirList => #{response.body}")
            @logger.debug("InterfaceHandlerHTTP::getDirList => NEED TO DO SUPER-CURL")
         end
         file_dirs = "/tmp/list_nasa_cddis_302_#{Time.now.to_f}.#{Random.new.rand(1.5)}.html"
         getFileWithRedirection(url, file_dirs, user, pass, @logger, @isDebugMode)
         doc = Nokogiri::HTML(File.open(file_dirs))
         # Filter by class archiveItemText and attribute href c1pg0480.25i.Z
         arr         = Array.new
         linkFiles   = doc.css('.archiveItemText')
         linkFiles.each{|linkFile|
            link = "#{url}#{linkFile.text}"
            arr << link
            if @isDebugMode == true
               @logger.debug(link)
            end
         }        
         File.delete(file_dirs)
         return arr
      end

      if @isDebugMode == true and response.code.to_i == 200 then 
         @logger.debug("InterfaceHandlerHTTP::getDirList => #{response.body}")
      end
              
      if response.code.to_i == 404 or response.code.to_i == 400 then
         if shortCircuit == true then 
            raise "I/F #{@entity}: #{response.code} / #{url}"
         else
            @logger.error("InterfaceHandlerHTTP::getDirList => I/F #{@entity}: #{response.code} / #{url}")
         end
      end
      ## ------------------
      
      ## https://stackoverflow.com/questions/39653384/how-to-extract-html-links-and-text-using-nokogiri-and-xpath-and-css
      
      arr   = Array.new
      doc   = Nokogiri::HTML.parse(response.body)
      
      # Get all anchors via xpath
      
      # tags  = doc.xpath("//a")
      
      tags  = doc.xpath('//a/@href')
      
      tags.each do |tag|
         if tag.text.include?('http://') == true or tag.text.include?('https://') == true then
            if @isDebugMode == true then
               @logger.debug("InterfaceHandlerHTTP::getDirList => item tag full URL => #{tag}")
            end
            if @isSecure == true then
               arr << tag.text.to_s.gsub("http://", "https://")
            else
               arr << tag.text
            end
         else
            if @isDebugMode == true then
               @logger.debug("InterfaceHandlerHTTP::getDirList => item tag relative URL => #{url}#{tag.text}")
            end
            arr << "#{url}#{tag.text}"
         end
      end

=begin
      if @maxDepth > 0 then
         arrDepth = Array.new
         
         arr.each do |url|
            arrDepth << getListFile(url)
         end

         @maxDepth = @maxDepth - 1


         return arrDepth
      end
=end

      return arr
   end
	## -----------------------------------------------------------

   # the URL refers to a specific file
   # however some files such as page_1.html are referring to the final target:
   # https://e4ftl01.cr.usgs.gov/MEASURES/SRTMGL1.003/2000.02.11/SRTMGL1_page_1.html
   # those kind of files should be treated such as directories
   #
   #  <tbody>
   #     <tr>
   #        <td><img src="http://e4ftl01.cr.usgs.gov//icons/image2.gif" alt="[IMG]"></td>
   #        <td><a href="http://e4ftl01.cr.usgs.gov/MEASURES/SRTMGL1.003/2000.02.11/N00E006.SRTMGL1.2.jpg">N00E006.SRTMGL1.2.jpg</a> </td>
   #        <td>2014-10-22 14:38</td>
   #        <td>191K</td>
   #        <td>None</td>
   #     </tr>
   #

   def getListFile(remotePath, shortCircuit = false)

      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::getListFile => #{remotePath} / DepthSearch = #{@maxDepth}")
      end

      # if it ends with "/" also

      if (remotePath.include?('page') and ( remotePath.include?('html') or  remotePath.include?('htm') ) ) or remotePath[-1,1] == '/' then  # or (@maxDepth > 0)
         if @isDebugMode == true then
            @logger.debug("InterfaceHandlerHTTP::getListFile => #{remotePath} refers to page navigation html")
            @logger.debug("InterfaceHandlerHTTP::getListFile => #{remotePath} url treated as a directory")
         end
         return getDirList(remotePath, shortCircuit)
      end

      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::getListFile => #{remotePath} url treated as a file")
      end

      require 'net/https'
      require 'uri'

      host        = ""
      url         = ""
      port        = @server[:port].to_i
      user        = @server[:user]
      pass        = @server[:password]
   
      if @isSecure == false then
         host        = "http://#{@server[:hostname]}:#{@server[:port]}/"
      else
         host        = "https://#{@server[:hostname]}/"
      end

      url = "#{host}#{remotePath}"

      if @isDebugMode == true then
         @logger.debug(url)
      end


      begin

         bFound   = false
         req      = Curl::Easy.new(url)
         
         if @verifyPeerSSL == false then
            if @isDebugMode == true and @logger != nil then
               @logger.debug("InterfaceHandlerHTTP::getListFile => #{@entity} I/F: HTTP HEAD VerifyPeerSSL is disabled")
            end
            req.ssl_verify_peer = false
            req.ssl_verify_host = false
         end

         if user != nil and user != "" then
            req.username = user
         end

         if pass != nil and pass != "" then
            req.password = pass
         end

         ret = true

         begin
            req.http_head
            ret = req.perform
         rescue Exception => e
            bFound = false
            ret    = false
            @logger.error("[DEC_614] I/F #{@entity}: Cannot HEAD #{url}")
            return nil
            #raise "[DEC_614] I/F #{@entity}: Cannot HEAD #{url}"
         end

         if ret == true then
            bFound = true
            if @isDebugMode == true then
               @logger.debug("Found #{File.basename(url)}")
            end
            return url
         end
         
         if @isDebugMode == true and bFound == true then
            @logger.debug("#{url} => #{ret.status}")
         end
                        
         ## -----------------------------------
         ## Permanent re-direction
         if ret.status.include?("301") == true then               
            new_url = ret.header_str.split("location:")[1].split("\n")[0].gsub(/\s+/, "")
            url = new_url
            bFound = true
            if @isDebugMode == true then
               @logger.debug("Found #{File.basename(new_url)}")
            end
         end
            
         ## -----------------------------------
                        
         if ret.status.include?("200") == true then
            bFound = true
            
            if @isDebugMode == true then
               @logger.debug("Found #{File.basename(url)}")
            end
         end

         if bFound == false then
            @logger.error("[DEC_614] I/F #{@entity}: Cannot HEAD #{url}")
         end
      rescue Exception => e
         @logger.error("[DEC_614] I/F #{@entity}: Cannot HEAD #{url}")
         @logger.error(e.to_s)
         if @isDebugMode == true then
            @logger.debug(e.backtrace)
         end
      end
         
      ## -----------------------------------
      
      return url  
   
   end
	## -------------------------------------------------------------
   
   ## -------------------------------------------------------------
   ##
   ## download file using HTTP protocol verb GET 
   ##
   def downloadFile(url)
      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::downloadFile => #{url}")
      end

      filename = File.basename(url)

      if @isDebugMode == true then
         @logger.debug("InterfaceHandlerHTTP::downloadFile => #{url} url treated as a file / #{filename}")
      end
      
      user        = @server[:user]
      pass        = @server[:password]

      begin
         http = Curl::Easy.new(url)
         # HTTP "insecure" SSL connections (like curl -k, --insecure) to avoid Curl::Err::SSLCACertificateError
         http.ssl_verify_peer = @verifyPeerSSL
         # Curl::Err::SSLPeerCertificateError ?????
         http.ssl_verify_host = false      
         http.http_auth_types = :basic
         
         if user != "" and user != nil then
            http.username = user
         end
         
         if pass != "" and pass != nil then
            http.password = pass
         end
   
         ret = http.perform
         
         if @isDebugMode == true then
            @logger.debug("#{user}:#{pass} => response code #{http.response_code}")
         end
   
         if http.response_code == 302 or http.response_code == 401 then
            return getFileWithRedirection(url, filename, user, pass, @logger, @isDebugMode)
         end
   
         if http.response_code == 301 then
            return getURLFile(url, filename, false, nil, nil, @logger, @isDebugMode)
         end
   
         if http.response_code == 200 then
            if @isDebugMode == true then
               @logger.debug("Generating file #{Dir.pwd}/#{filename}")
            end
            aFile = File.new(filename, "wb")
            # aFile.write(http.body)
            aFile.write(http.body_str)
            aFile.flush
            aFile.close
            return true
         end

      rescue Exception => e
         ret = getFileWithRedirection(url, filename, user, pass, @logger, @isDebugMode)
      end

      @logger.error("Unexpected error for #{url}")
      @logger.error("#{url} => #{http.response_code}")
      @logger.error("#{http.body_str}")
      
      puts ret
      puts http.body_str
      puts http.response_code
  
      raise "Problems come to me"
          
   end
      
   ## -------------------------------------------------------------


private




end # class

end # module
