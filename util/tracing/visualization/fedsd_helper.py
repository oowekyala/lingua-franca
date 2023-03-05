import math

# Disctionary for pruning event names. Usefule for tracepoint matching and
# communication rendering
prune_event_name = {
    "Federate sends TIMESTAMP to RTI": "TIMESTAMP",
    "Federate sends NET to RTI": "NET",
    "Federate sends LTC to RTI": "LTC",
    "Federate sends STOP_REQ to RTI": "STOP_REQ",
    "Federate sends STOP_REQ_REP to RTI": "STOP_REQ_REP",
    "Federate receives ACK from RTI": "ACK",
    "Federate receives REJECT from RTI": "REJECT",
    "Federate receives TIMESTAMP from RTI": "TIMESTAMP",
    "Federate receives PTAG from RTI": "PTAG",
    "Federate receives TAG from RTI": "TAG",
    "Federate receives STOP_REQ from RTI": "STOP_REQ",
    "Federate receives STOP_GRN from RTI": "STOP_GRN",
    "Federate sends FED_ID to federate": "FED_ID",
    "Federate receives FED_ID from federate": "FED_ID",
    "RTI sends ACK to federate": "ACK",
    "RTI sends REJECT to federate": "REJECT",
    "RTI sends TIMESTAMP to federate": "TIMESTAMP",
    "RTI sends PTAG to federate": "PTAG",
    "RTI sends TAG to federate": "TAG",
    "RTI sends STOP_REQ to federate": "STOP_REQ",
    "RTI sends STOP_GRN to federate": "STOP_GRN",
    "RTI sends JOIN to federate": "JOIN", 
    "RTI receives TIMESTAMP from federate": "TIMESTAMP",
    "RTI receives NET from federate": "NET",
    "RTI receives LTC from federate": "LTC",
    "RTI receives STOP_REQ from federate": "STOP_REQ",
    "RTI receives STOP_REQ_REP from federate": "STOP_REQ_REP"
}

prune_event_name.setdefault(" ", "UNIDENTIFIED")

################################################################################
### Routines to write to csv file
################################################################################

def svg_string_draw_line(x1, y1, x2, y2, dashed):
    '''
    Constructs the svg html string to draw a line from (x1, y1) to (x2, y2). The 
    line can be continous or dashed.

    Args:
     * x1: Int X coordinate of the source point
     * y1: Int Y coordinate of the source point
     * x2: Int X coordinate of the sink point
     * y2: Int Y coordinate of the sink point
     * dashed: Bool True if the line is dashed, continous otherwise
    Returns:
     * String: the svg string of the line
    '''
    str_line = '\t<line x1="'+str(x1)+'" y1="'+str(y1)+'" x2="'+str(x2)+'" y2="'+str(y2)+'" stroke="black" stroke-width="2"'
    if (dashed):
        str_line = str_line + ' stroke-dasharray="10,10" '
    str_line = str_line +  '/>\n'
    return str_line


def svg_string_draw_arrow_head(x1, x2, y2) :
    '''
    Constructs the svg html string to draw the arrow end

    Args:
     * x1: Int X coordinate of the source point
     * x2: Int X coordinate of the sink point
     * y2: Int Y coordinate of the sink point
    Returns:
     * String: the svg string of the triangle
    '''
    str_line = ''
    if (x1 > x2) :
        str_line = '\t<path d="M'+str(x2)+' '+str(y2)+' L'+str(x2+10)+' '+str(y2+5)+' L'+str(x2+10)+' '+str(y2-5)+' Z" />\n'
    else :
        str_line = '\t<path d="M'+str(x2)+' '+str(y2)+' L'+str(x2-10)+' '+str(y2+5)+' L'+str(x2-10)+' '+str(y2-5)+' Z" />\n'
    return str_line


def svg_string_draw_label(x1, y1, x2, y2, label) :
    '''
    Computes the rotation angle of the text and then constructs the svg string. 

    Args:
     * x1: Int X coordinate of the source point
     * y1: Int Y coordinate of the source point
     * x2: Int X coordinate of the sink point
     * y2: Int Y coordinate of the sink point
     * label: Bool True if the line is dashed, continous otherwise
    Returns:
     * String: the svg string of the text
    '''
    # FIXME: Need further improvement, based of the position of the arrows
    # FIXME: Rotation value is not that accurate. 
    if (x2 < x1) :
        rotation = - math.ceil(math.atan((x2-x1)/(y2-y1)) * 180 / 3.14) - 90
        str_line = '\t<text transform="translate('+str(x2+5)+', '+str(y2-5)+') rotate('+str(rotation)+')" font-size="smaller">'+label+'</text>\n'
    else :
        rotation = - math.ceil(math.atan((x1-x2)/(y1-y2)) * 180 / 3.14) + 90
        x = math.ceil((x2 + x1) / 2)
        y = math.ceil((y1 + y2) / 2) - 5
        str_line = '\t<text transform="translate('+str(x)+', '+str(y)+') rotate('+str(rotation)+')" font-size="smaller" text-anchor="middle">'+label+'</text>\n'
    #print('rot = '+str(rotation)+' x1='+str(x1)+' y1='+str(y1)+' x2='+str(x2)+' y2='+str(y2))
    return str_line


def svg_string_draw_arrow(x1, y1, x2, y2, label, dashed):
    '''
    Constructs the svg html string to draw the arrow from (x1, y1) to (x2, y2). 
    The arrow end is constructed, together with the label

    Args:
     * x1: Int X coordinate of the source point
     * y1: Int Y coordinate of the source point
     * x2: Int X coordinate of the sink point
     * y2: Int Y coordinate of the sink point
     * label: String Label to draw on top of the arrow
     * dashed: Bool True if the line is dashed, continous otherwise
    Returns:
     * String: the svg string of the arrow
    '''
    str_line1 = svg_string_draw_line(x1, y1, x2, y2, dashed)
    str_line2 = svg_string_draw_arrow_head(x1, x2, y2)
    str_line3 = svg_string_draw_label(x1, y1, x2, y2, label)
    return str_line1 + str_line2 + str_line3


def svg_string_comment(comment):
    '''
    Constructs the svg html string to write a comment into an svg file.

    Args:
     * comment: String Comment to add
    Returns:
     * String: the svg string of the comment
    '''
    str_line = '\n\t<!-- ' + comment + ' -->\n'
    return str_line


def svg_string_draw_dot(x, y, label) :
    '''
    Constructs the svg html string to draw the arrow end

    Args:
     * x: Int X coordinate of the dot
     * y: Int Y coordinate of the dot
     * label: String 
    Returns:
     * String: the svg string of the triangle
    '''
    str_line = ''
    str_line = '\t<circle cx="'+str(x)+'" cy="'+str(y)+'" r="5" stroke="black" stroke-width="1" fill="black"/>\n'
    str_line = str_line + '\t<text x="'+str(x+5)+'", y="'+str(y+2)+'" fill="blue" font-size="smaller">'+label+'</text>\n'
    return str_line