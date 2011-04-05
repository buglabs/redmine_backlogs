require 'rubygems'
require 'prawn'
require 'prawn/measurement_extensions'
require 'net/http'
require 'rexml/document'

require 'yaml'
require 'uri/common'

module Cards
    class TaskboardCards
        include Redmine::I18n
        
        begin
          LABELS = YAML::load_file(File.dirname(__FILE__) + '/labels.yaml')
        rescue
          LABELS = {}
        end
        
        def self.selected_label
            return nil if not Setting.plugin_redmine_backlogs[:card_spec]
            return LABELS[Setting.plugin_redmine_backlogs[:card_spec]]
        end
    
        def initialize(lang)
            set_language_if_valid lang

            raise "No label stock selected" unless Setting.plugin_redmine_backlogs[:card_spec]
            label = TaskboardCards.selected_label
            raise "Label stock \"#{Setting.plugin_redmine_backlogs[:card_spec]}\" not found" unless label

            label['papersize'].upcase!
    
            geom = Prawn::Document::PageGeometry::SIZES[label['papersize']]
            raise "Paper size '#{label['papersize']}' not supported" if geom.nil?
    
            @paper_width = geom[0]
            @paper_height = geom[1]
    
            @top_margin = TaskboardCards.topts(label['top_margin'])
            @vertical_pitch = TaskboardCards.topts(label['vertical_pitch'])
            @height = TaskboardCards.topts(label['height'])
    
            @left_margin = TaskboardCards.topts(label['left_margin'])
            @horizontal_pitch = TaskboardCards.topts(label['horizontal_pitch'])
            @width = TaskboardCards.topts(label['width'])
    
            @across = label['across']
            @down = label['down']
    
            @inner_margin = TaskboardCards.topts(label['inner_margin']) || 1.mm
    
            @pdf = Prawn::Document.new(
                :page_layout => :portrait,
                :left_margin => 0,
                :right_margin => 0,
                :top_margin => 0,
                :bottom_margin => 0,
                :page_size => label['papersize'])

            fontdir = File.dirname(__FILE__) + '/ttf'
            @pdf.font_families.update(
              "DejaVuSans" => {
                :bold         => "#{fontdir}/DejaVuSans-Bold.ttf",
                :italic       => "#{fontdir}/DejaVuSans-Oblique.ttf",
                :bold_italic  => "#{fontdir}/DejaVuSans-BoldOblique.ttf",
                :normal       => "#{fontdir}/DejaVuSans.ttf"
              }
            )
            @pdf.font "DejaVuSans"

    
            @cards = 0
        end
    
        def self.measurement(x)
          x = "#{x}pt" if x =~ /[0-9]$/
          return x
        end

        def self.malformed(label)
          return TaskboardCards.topts(label['height']) > TaskboardCards.topts(label['vertical_pitch']) || TaskboardCards.topts(label['width']) > TaskboardCards.topts(label['horizontal_pitch'])
        end

        def self.fetch_labels
            LABELS.keys.each {|label|
              if TaskboardCards.malformed(LABELS[label])
                LABELS.delete(label)
                puts "Removing malformed label '#{label}'"
              end
            }

            malformed_labels = {}

            ['avery-iso-templates.xml',
             'avery-other-templates.xml',
             'avery-us-templates.xml',
             'brother-other-templates.xml',
             'dymo-other-templates.xml',
             'maco-us-templates.xml',
             'misc-iso-templates.xml',
             'misc-other-templates.xml',
             'misc-us-templates.xml',
             'pearl-iso-templates.xml',  
             'uline-us-templates.xml',
             'worldlabel-us-templates.xml',
             'zweckform-iso-templates.xml'].each {|filename|
                uri = URI.parse("http://git.gnome.org/browse/glabels/plain/templates/#{filename}")
                labels = nil

                if ! ENV['http_proxy'].blank?
                  begin
                    proxy = URI.parse(ENV['http_proxy'])
                    if proxy.userinfo
                      user, pass = proxy.userinfo.split(/:/)
                    else
                      user = pass = nil
                    end
                    labels = Net::HTTP::Proxy(proxy.host, proxy.port, user, pass).start(uri.host) {|http| http.get(uri.path)}.body
                  rescue URI::Error => e
                    puts "Setup proxy failed: #{e}"
                    labels = nil
                  end
                end

                begin
                  labels = Net::HTTP.get_response(uri).body if labels.nil?
                rescue
                  labels = nil
                end

                if labels.nil?
                  puts "Could not fetch #{filename}"
                  next
                end

                doc = REXML::Document.new(labels)
    
                doc.elements.each('Glabels-templates/Template') do |specs|
                    label = nil
    
                    papersize = specs.attributes['size']
                    papersize = 'Letter' if papersize == 'US-Letter'
    
                    specs.elements.each('Label-rectangle') do |geom|
                        margin = nil
                        geom.elements.each('Markup-margin') do |m|
                            margin = m.attributes['size']
                        end
                        margin = "1mm" if margin.blank?
    
                        geom.elements.each('Layout') do |layout|
                            label = {
                                'inner_margin' => TaskboardCards.measurement(margin),
                                'across' => Integer(layout.attributes['nx']),
                                'down' => Integer(layout.attributes['ny']),
                                'top_margin' => TaskboardCards.measurement(layout.attributes['y0']),
                                'height' => TaskboardCards.measurement(geom.attributes['height']),
                                'horizontal_pitch' => TaskboardCards.measurement(layout.attributes['dx']),
                                'left_margin' => TaskboardCards.measurement(layout.attributes['x0']),
                                'width' => TaskboardCards.measurement(geom.attributes['width']),
                                'vertical_pitch' => TaskboardCards.measurement(layout.attributes['dy']),
                                'papersize' => papersize,
                                'source' => 'glabel'
                            }
                        end
                    end
    
                    next if label.nil?
    
                    key = "#{specs.attributes['brand']} #{specs.attributes['part']}"

                    if TaskboardCards.malformed(label)
                      puts "Skipping malformed label '#{key}' from #{filename}"
                      malformed_labels[key] = label
                    else
                      LABELS[key] = label if not LABELS[key] or LABELS[key]['source'] == 'glabel'
    
                      specs.elements.each('Alias') do |also|
                          key = "#{also.attributes['brand']} #{also.attributes['part']}"
                          LABELS[key] = label.dup if not LABELS[key] or LABELS[key]['source'] == 'glabel'
                      end
                    end
                end
            }
    
            File.open(File.dirname(__FILE__) + '/labels.yaml', 'w') do |dump|
                YAML.dump(LABELS, dump)
            end
            File.open(File.dirname(__FILE__) + '/labels-malformed.yaml', 'w') do |dump|
                YAML.dump(malformed_labels, dump)
            end

            if Setting.plugin_redmine_backlogs[:card_spec] && ! TaskboardCards.selected_label && LABELS.size != 0
              # current label non-existant
              label = LABELS.keys[0]
              puts "Non-existant label stock '#{Setting.plugin_redmine_backlogs[:card_spec]}' selected, replacing with random '#{label}'"
              s = Setting.plugin_redmine_backlogs
              s[:card_spec] = label
              Setting.plugin_redmine_backlogs = s
            end
        end
    
        attr_reader :pdf
    
        def card(issue, type)
            row = (@cards % @down) + 1
            col = ((@cards / @down) % @across) + 1
            @cards += 1
    
            @pdf.start_new_page if row == 1 and col == 1 and @cards != 1
    
            parent_story = issue.story
    
            # card bounds
            @pdf.bounding_box self.top_left(row, col), :width => @width, :height => @height do
                @pdf.line_width = 0.5
                @pdf.stroke do
                    @pdf.stroke_bounds
                    
                    # card margin
                    @pdf.bounding_box [@inner_margin, @height - @inner_margin],
                                        :width => @width - (2 * @inner_margin),
                                        :height => @height - (2 * @inner_margin) do
    
                        scoresize = 0

                        # Estimated hours, or points if they exist
                        @y = @pdf.bounds.bottom + 12
                        @pdf.font_size(12) do
                            score = (type == :task ? issue.estimated_hours.to_i : issue.story_points.to_i)
			    score = ( score == 0 ? ( type == :task ? '??' : '' ) : "#{score}" )
                            scoresize = @pdf.width_of(" #{score} ")
    
                            text_box(score, {
                                    :width => scoresize,
                                    :height => @pdf.font.height
                                } )
                        end
    
                        # Task and Story trail
                        @y = @pdf.bounds.height
                        pos = parent_story.position ? parent_story.position : l(:label_not_prioritized)
                        trail = (issue.self_and_ancestors.reverse.collect{|i| "#{i.tracker.name} ##{i.id}"}.join(" : ")) + " (#{pos})"
                        @pdf.font_size(6) do
                            text_box(trail, {
                                    :width => pdf.bounds.width - scoresize,
                                    :height => @pdf.font.height,
                                    :align => :center,
                                    :style => :italic
                                })
                        end
    
                        # Task or User Story 
                        text_box issue.subject, {
                                :width => pdf.bounds.width,
                                :height => @pdf.bounds.height - @pdf.font.height,
                                :align => :center,
                                :valign => :center
                            }
    
                        # User Name
			begin
			  user = User.find(issue.assigned_to_id)
			rescue
			  user = ""
			end
			if user===""
			  initials=""
			else
			  initials = user.firstname.first + user.lastname.first
			end
			initials_width = @pdf.width_of("_#{initials}_")
                        @y = @pdf.bounds.height
                        @pdf.font_size(12) do
                            text_box( initials, {
			        :width => initials_width,
				:height => @pdf.font.height
                            }, @pdf.bounds.width - initials_width)
			end
                    end
                end
            end
        end
    
        def add(story, add_tasks = true)
            if add_tasks
                story.descendants.each {|task|
                    card(task, :task)
                }
            end
    
            card(story, :story)
        end
    
        def text_box(s, options, x = 0)
            box = Prawn::Text::Box.new(s, options.merge(:overflow => :ellipses, :at => [x, @y], :document => @pdf))
            box.render
            @y -= (options[:height] + (options[:size] || @pdf.font_size) / 2)
            return box
        end
    
        def self.topts(v)
            return nil if v.class == NilClass

            if v =~ /[a-z]{2}$/i
              units = v[-2, 2].downcase
              v = v[0..-3]
            else
              units = 'pt'
            end

            v = "#{v}0" if v =~ /\.$/

            return Float(v).mm if units == 'mm'
            return Float(v).cm if units == 'cm'
            return Float(v).in if units == 'in'
            return Float(v).pt if units == 'pt'
            raise "Unexpected units '#{units}'"
        end
    
        def top_left(row, col)
            top = @paper_height - (@top_margin + @vertical_pitch * (row - 1))
            left = @left_margin + (@horizontal_pitch * (col - 1))
            return [left, top]
        end
    end

end
