=begin
                  Arachni
  Copyright (c) 2010-2011 Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>

  This is free software; you can copy and distribute and modify
  this program under the term of the GPL v2.0 License
  (See LICENSE file for details)

=end

require 'erb'
require 'base64'
require 'cgi'
require 'iconv'

module Arachni

require Options.instance.dir['lib'] + 'crypto/rsa_aes_cbc'

module Reports

#
# Creates an HTML report of the audit.
#
# @author: Tasos "Zapotek" Laskos
#                                      <tasos.laskos@gmail.com>
#                                      <zapotek@segfault.gr>
# @version: 0.3
#
class HTML < Arachni::Report::Base

    module Utils

        def for_anomalous_metamodules( audit_store, &block )
            audit_store.plugins['metamodules'][:results].each_pair {
                |metaname, data|
                next if !data[:tags] || !data[:tags].include?( 'anomaly' )
                block.call( metaname, data )
            }
        end

        def erb( tpl, params = {} )
            scope = TemplateScope.instance.add_hash( params )

            tpl = tpl.to_s + '.erb' if tpl.is_a?( Symbol )

            path = File.exist?( tpl ) ? tpl : @base_path + tpl
            ERB.new( IO.read( path ) ).result( scope.get_binding )
        end
    end

    include Utils

    class TemplateScope
        include Singleton
        include Utils

        REPORT_FP_URL = "https://github.com/Zapotek/arachni/issues"

        def add_hash( params )
            params.each_pair {
                |name, value|
                add( name, value )
            }
            self
        end

        def add( name, value )
            self.class.send( :attr_accessor, name )
            instance_variable_set( "@#{name.to_s}", value )
            self
        end

        def format_issue( hash )
            idx, issue = find_issue_by_hash( hash )
            erb :issue, {
                :idx   => idx,
                :issue => issue
            }
        end

        def find_issue_by_hash( hash )
            @audit_store.issues.each_aith_index {
                |issue, i|
                return [i+1, issue] if issue._hash == hash
            }
            return nil
        end

        def get_meta_info( name )
            @audit_store.plugins['metamodules'][:results][name]
        end

        def get_plugin_info( name )
            @audit_store.plugins[name]
        end

        def js_multiline( str )
          "\"" + str.gsub( "\n", '\n' ) + "\"";
        end

        def normalize( str )
            return str if !str || str.empty?

            ic = ::Iconv.new( 'UTF-8//IGNORE', 'UTF-8' )
            ic.iconv( str + ' ' )[0..-2]
        end

        def escapeHTML( str )
            # carefully escapes HTML and converts to UTF-8
            # while removing invalid character sequences
            return CGI.escapeHTML( normalize( str ) )
        end

        def get_binding
            binding
        end
    end

    #
    # @param [AuditStore]  audit_store
    # @param [Hash]   options    options passed to the report
    #
    def initialize( audit_store, options )
        @audit_store   = audit_store
        @options       = options

        @crypto = RSA_AES_CBC.new( Options.instance.dir['data'] + 'crypto/public.pem' )
    end

    #
    # Runs the HTML report.
    #
    def run( )

        print_line( )
        print_status( 'Creating HTML report...' )

        plugins   = format_plugin_results( @audit_store.plugins )
        base_path = File.dirname( @options['tpl'] ) + '/' +
            File.basename( @options['tpl'], '.erb' ) + '/'

        conf = {}
        conf['options']  = @audit_store.options
        conf['version']  = @audit_store.version
        conf['revision'] = @audit_store.revision
        conf = @crypto.encrypt( conf.to_yaml )

        params = __prepare_data.merge(
            :conf        => conf,
            :audit_store => @audit_store,
            :plugins     => plugins,
            :base_path   => base_path
        )

        __save( @options['outfile'], erb( @options['tpl'], params ) )

        print_status( 'Saved in \'' + @options['outfile'] + '\'.' )
    end

    def self.info
        {
            :name           => 'HTML Report',
            :description    => %q{Exports a report as an HTML document.},
            :author         => 'Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>',
            :version        => '0.2',
            :options        => [
                Arachni::OptPath.new( 'tpl', [ false, 'Template to use.',
                    File.dirname( __FILE__ ) + '/html/default.erb' ] ),
                Arachni::OptString.new( 'outfile', [ false, 'Where to save the report.',
                    Time.now.to_s + '.html' ] ),
            ]
        }
    end

    private

    def self.prep_description( str )
        placeholder =  '--' + rand( 1000 ).to_s + '--'
        cstr = str.gsub( /^\s*$/xm, placeholder )
        cstr.gsub!( /^\s*/xm, '' )
        cstr.gsub!( placeholder, "\n" )
        cstr.chomp
    end


    def __save( outfile, out )
        file = File.new( outfile, 'w' )
        file.write( out )
        file.close
    end

    def __prepare_data( )

        graph_data = {
            :severities => {
                Issue::Severity::HIGH => 0,
                Issue::Severity::MEDIUM => 0,
                Issue::Severity::LOW => 0,
                Issue::Severity::INFORMATIONAL => 0,
            },
            :issues     => {},
            :elements   => {
                Issue::Element::FORM => 0,
                Issue::Element::LINK => 0,
                Issue::Element::COOKIE => 0,
                Issue::Element::HEADER => 0,
                Issue::Element::BODY => 0,
                Issue::Element::PATH => 0,
                Issue::Element::SERVER => 0,
            },
            :verification => {
                'Yes' => 0,
                'No'  => 0
            }
        }

        total_severities = 0
        total_elements   = 0
        total_verifications = 0

        crypto_issues = []

        filtered_hashes  = []
        anomalous_hashes = []

        anomalous_meta_results = {}
        for_anomalous_metamodules( @audit_store ) {
            |metaname, data|
            anomalous_meta_results[metaname] = data
        }

        @audit_store.issues.each_with_index {
            |issue, i|

            crypto_issues << @crypto.encrypt( issue.to_yaml )

            graph_data[:severities][issue.severity] ||= 0
            graph_data[:severities][issue.severity] += 1
            total_severities += 1

            graph_data[:issues][issue.name] ||= 0
            graph_data[:issues][issue.name] += 1

            graph_data[:elements][issue.elem] ||= 0
            graph_data[:elements][issue.elem] += 1
            total_elements += 1

            verification = issue.verification ? 'Yes' : 'No'
            graph_data[:verification][verification] ||= 0
            graph_data[:verification][verification] += 1
            total_verifications += 1

            issue.variations.each_with_index {
                |variation, j|

                if( variation['response'] && !variation['response'].empty? )

                    variation['response'] = variation['response'].force_encoding( 'utf-8' )

                    @audit_store.issues[i].variations[j]['escaped_response'] =
                        Base64.encode64( variation['response'] ).gsub( /\n/, '' )
                end

                response = {}
                if !variation['headers']['response'].is_a?( Hash )
                    variation['headers']['response'].split( "\n" ).each {
                        |line|
                        field, value = line.split( ':', 2 )
                        next if !value
                        response[field] = value
                    }
                end
                variation['headers']['response'] = response.dup

            }

            if !anomalous?( anomalous_meta_results, issue )
                filtered_hashes << issue._hash
            else
                anomalous_hashes << issue._hash
            end

        }

        graph_data[:severities].each {
            |severity, cnt|
            graph_data[:severities][severity] ||= 0
            begin
                graph_data[:severities][severity] = ((cnt/Float(total_severities)) * 100).to_i
            rescue
            end
        }

        graph_data[:elements].each {
            |elem, cnt|
            graph_data[:elements][elem] ||= 0

            begin
                graph_data[:elements][elem] = ((cnt/Float(total_elements)) * 100).to_i
            rescue
            end
        }

        graph_data[:verification].each {
            |verification, cnt|
            graph_data[:verification][verification] ||= 0

            begin
                graph_data[:verification][verification] = ((cnt/Float(total_verifications)) * 100).to_i
            rescue
            end
        }

        {
            :graph_data          => graph_data,
            :total_severities    => total_severities,
            :total_elements      => total_elements,
            :total_verifications => total_verifications,
            :crypto_issues       => crypto_issues,
            :filtered_hashes     => filtered_hashes,
            :anomalous_hashes    => anomalous_hashes,
            :anomalous_meta_results => anomalous_meta_results
        }

    end

    def anomalous?( anomalous_meta_results, issue )
        anomalous_meta_results.each_pair {
            |metaname, data|
            data[:results].each {
                |m_issue|
                return true if m_issue['hash'] == issue._hash
            }
        }

        return false
    end

end

end
end
